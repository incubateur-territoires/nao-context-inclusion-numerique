"""DAG coop-import — ce qui reste du flux coop côté entrepôt.

Historique des retraits (SEPT #1707 / #1724) :
- V144 : activités → vue sur coop.activites (plus de réplication).
- f372fe3 : SA, personnes, affectations emploi → écrites par la coop.
- V151 : affectations lieu → vue sur coop.mediateurs_en_activite.
- V157 : coordination_mediation supprimée (coop.mediateurs_coordonnes fait foi).
- V159 : plus d'import des structures par API — la vue d'union
  main.lieu_inclusion (V153) lit coop.lieu_inclusion en direct ; il ne reste
  à maintenir que l'IDENTITÉ des lieux dans main.lieu_inclusion,
  assurée par le filet SQL `reconcilier_registre_lieux`
  (etl/load/registre_lieux_coop.py, lot 2 du contrat d'écriture synchrone).
  Retirés : fetch/transform structures, géocodage BAN, ingest_structures,
  build_role_index, source/staging.coop__structures, contrat coop__structures.

Reste le fetch /api/v1/utilisateurs (capture brute + silver) : plus aucun
consommateur depuis le retrait de build_role_index — à retirer avec
source/staging.coop__utilisateurs (MR suivante).
"""
import json
import logging
from datetime import timedelta

import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.python import ShortCircuitOperator
from airflow.providers.standard.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sdk import Param
from etl.core.coop import dedupe_par_id
from etl.core.coop import transformer_utilisateurs
from etl.extract.connectors.http_airflow import APIClientOperator
from mattermost_notifier import MattermostNotifier

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 3,
    "retry_delay": timedelta(minutes=2),
    "retry_exponential_backoff": True,
}


def _get_notifier():
    """Lazy init du notifier pour éviter Variable.get() au top-level."""
    if not hasattr(_get_notifier, "_instance"):
        _get_notifier._instance = MattermostNotifier(
            webhook_url=Variable.get("MATTERMOST_WEBHOOK_URI"),
            default_channel=Variable.get("MATTERMOST_NOTIFICATION_CHANNEL"),
        )
    return _get_notifier._instance


def dag_success_callback(context):
    _get_notifier().notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    _get_notifier().notify(context, "DAG", "FAILURE")


# ---------------------------------------------------------------------------
# Filet registre des lieux (V159, lot 2 #1724) — SQL direct sur coop.*
# ---------------------------------------------------------------------------
def reconcilier_registre_lieux(**kwargs):
    """Garantit une ligne d'identité main.lieu_inclusion (avec adresse
    résolue par main.trouver_ou_creer_adresse_lieu) pour tout lieu vivant de
    coop.lieu_inclusion. Idempotent, no-op sans schéma coop (CI)."""
    from etl.load.registre_lieux_coop import reconcilier_registre_lieux as filet

    conn = PostgresHook(postgres_conn_id=kwargs["params"]["db_conn_id"]).get_conn()
    try:
        return filet(conn)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Flux utilisateurs : capture brute (source) + silver (staging), via le core
# pur etl/core/coop.py — sans consommateur aval depuis V159.
# ---------------------------------------------------------------------------
COOP_UTILISATEURS_COLS = [
    "coop_id",
    "updated_at_coop",
    "deleted_at_coop",
    "nom",
    "prenom",
    "contact",
    "cn_pg_id",
    "is_visible",
    "conseiller_numerique_id",
    "is_mediateur",
    "is_coordinateur",
    "personne_affectations",
]


def _lire_source_run(conn_id, table, run_id):
    """Objets bruts capturés dans `table` pour ce dag_run, dédupliqués par id."""
    hook = PostgresHook(postgres_conn_id=conn_id)
    rows = hook.get_records(
        f"SELECT donnee FROM {table} WHERE run_id = %s ORDER BY id",
        parameters=(run_id,),
    )
    return dedupe_par_id([r[0] for r in rows])


def _replace_staging_rows(conn, table, cols, rows, run_id):
    """TRUNCATE puis INSERT des lignes (liste de dicts) dans staging.<table>.

    Silver reconstruit à chaque run : la table ne porte que le dernier run,
    l'historique reste dans source.* (bronze). Insertion par tranches pour
    borner la mémoire.
    """
    from psycopg2.extras import execute_values

    insert_sql = f"INSERT INTO staging.{table} (run_id, {', '.join(cols)}) VALUES %s"
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE staging.{table}")
        for start in range(0, len(rows), 50_000):
            values = [
                [run_id] + [r.get(c) for c in cols]
                for r in rows[start : start + 50_000]
            ]
            execute_values(cur, insert_sql, values, page_size=1000)
    conn.commit()
    logging.info("Silver staging.%s : %d lignes (run %s).", table, len(rows), run_id)


def transform_utilisateurs(**kwargs):
    """Silver : source.coop__utilisateurs du run → core pur → staging."""
    conn_id = kwargs["params"]["db_conn_id"]
    run_id = kwargs["run_id"]
    items = _lire_source_run(conn_id, "source.coop__utilisateurs", run_id)
    rows = transformer_utilisateurs(items)
    # Colonnes structurées sérialisées en JSON (TEXT dans le silver) :
    # les lecteurs font json.loads / ::jsonb.
    for r in rows:
        for c in ("contact", "personne_affectations"):
            r[c] = json.dumps(r[c], ensure_ascii=False)
    conn = PostgresHook(postgres_conn_id=conn_id).get_conn()
    try:
        _replace_staging_rows(
            conn, "coop__utilisateurs", COOP_UTILISATEURS_COLS, rows, run_id
        )
    finally:
        conn.close()
    logging.info("%d utilisateurs (sur %d objets bruts).", len(rows), len(items))


def tests_main(**kwargs):
    """Tests qualité mode warn (fiche 03) : exécute les invariants SQL de
    tests/quality/ sur la base cible du run. Dead-end, jamais bloquant."""
    # Import lazy pour ne pas alourdir le parsing du DAG
    from etl.qualite_tests import executer_tests_qualite

    executer_tests_qualite(db_conn_id=kwargs["params"]["db_conn_id"])


def valider_contrat(table, contrat_nom, **kwargs):
    """Validation de contrat mode warn (fiche 02) : relit la capture brute
    du run dans `table` et la confronte à contracts/<contrat_nom>.yml.
    Dead-end, jamais bloquant."""
    # Import lazy pour ne pas alourdir le parsing du DAG
    from etl.contrat_validation import valider_contrat_source

    valider_contrat_source(
        table=table,
        contrat_nom=contrat_nom,
        db_conn_id=kwargs["params"]["db_conn_id"],
        run_id=kwargs["run_id"],
    )


with DAG(
    dag_id="coop-import",
    default_args=default_args,
    description=(
        "DAG coop : filet d'identité des lieux d'inclusion "
        "(coop.lieu_inclusion → main.lieu_inclusion, SQL direct) "
        "+ capture brute des utilisateurs. SA, personnes, emplois, activités, "
        "affectations lieu et coordination : gérés par la coop / vues (#1707)."
    ),
    schedule=None,
    dagrun_timeout=timedelta(minutes=900),
    on_success_callback=dag_success_callback,
    on_failure_callback=dag_failure_callback,
    start_date=pendulum.datetime(2024, 1, 1, tz="Europe/Paris"),
    catchup=False,
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            examples=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
    },
    tags=["coop", "api"],
) as dag:
    token = Variable.get("coop_api_token")
    headers = {"Authorization": f"Bearer {token}"}

    fetch_users_task = APIClientOperator(
        task_id="fetch_all_utilisateurs",
        conn_id="coop_api",
        endpoint="/api/v1/utilisateurs",
        data_type="coop_utilisateurs",
        headers=headers,
        do_xcom_push=False,
        source_table="source.coop__utilisateurs",
        source_db_conn_id="{{ params['db_conn_id'] }}",
    )

    valider_contrat_utilisateurs_task = PythonOperator(
        task_id="valider_contrat_utilisateurs",
        python_callable=valider_contrat,
        op_kwargs={
            "table": "source.coop__utilisateurs",
            "contrat_nom": "coop__utilisateurs",
        },
    )

    transform_utilisateurs_task = PythonOperator(
        task_id="transform_utilisateurs",
        python_callable=transform_utilisateurs,
    )

    reconcilier_registre_lieux_task = PythonOperator(
        task_id="reconcilier_registre_lieux",
        python_callable=reconcilier_registre_lieux,
    )

    # Invalidation du cache de la cartographie nationale : uniquement quand
    # l'exécution cible la base de production.
    check_prod_for_carto_cache_reset = ShortCircuitOperator(
        task_id="check_prod_for_carto_cache_reset",
        python_callable=lambda **ctx: ctx["params"]["db_conn_id"] == "sonum-prod-db",
    )
    trigger_carto_cache_reset = TriggerDagRunOperator(
        task_id="trigger_carto_cache_reset",
        trigger_dag_id="carto-cache-reset",
        reset_dag_run=True,
    )

    tests_main_task = PythonOperator(
        task_id="tests_main",
        python_callable=tests_main,
    )

    fetch_users_task >> [transform_utilisateurs_task, valider_contrat_utilisateurs_task]
    reconcilier_registre_lieux_task >> check_prod_for_carto_cache_reset >> trigger_carto_cache_reset
    # Tests qualité (mode warn) en branche dead-end après le filet.
    reconcilier_registre_lieux_task >> tests_main_task
