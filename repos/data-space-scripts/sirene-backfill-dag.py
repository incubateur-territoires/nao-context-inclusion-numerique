"""DAG de rattrapage SIRENE indépendant des flux sources.

Les pipelines d'import (coop, carto, idPoste) n'enrichissent `denomination_sirene`
/ `last_sirene_enrich_at` que pour les structures présentes dans leur flux source
courant. Une structure avec un SIRET mais absente de ces flux (carto-only,
idPoste-only, sortie du flux coop) reste NULL indéfiniment : rien ne la
re-sélectionne par son état.

Ce DAG comble ce trou : il sélectionne dans `main.structure_administrative`
TOUTES les structures avec un SIRET dont l'enrichissement est manquant ou
périmé, les enrichit via SireneBatch, et met à jour la base par `id` (pas par
`structure_coop_id`). Plafonné par run, plus anciens d'abord, pour drainer le
backlog progressivement sans saturer l'API INSEE.
"""

import logging
from datetime import timedelta

import pandas as pd
import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.python import PythonOperator
from airflow.sdk import Param

from mattermost_notifier import MattermostNotifier

DAG_ID = "sirene-backfill"
START_DATE = pendulum.datetime(2026, 1, 1, tz="Europe/Paris")

DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

# Colonnes renvoyées par SireneBatch.enrichir_dataframe que l'on persiste.
_SIRENE_COLS = (
    "etat_administratif",
    "code_activite_principale",
    "categorie_juridique",
    "denomination_sirene",
)

# Colonnes du silver staging.sirene__etablissements (V135), dans l'ordre de la
# sortie de SireneBatch.enrichir_dataframe. structure_id = id_source
# (main.structure_administrative.id), siret = siret_sirene (normalisé zfill(14)).
_SILVER_COLS = [
    "structure_id",
    "siret",
    "etat_administratif",
    "code_activite_principale",
    "categorie_juridique",
    "denomination_sirene",
    "adresse_sirene",
    "code_insee_sirene",
    "code_postal_sirene",
    "date_creation_sirene",
    "tranche_effectifs_sirene",
    "sirene_trouve",
]

_UPDATE_BATCH_SIZE = 500


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


def backfill_sirene(**kwargs):
    """Rattrape l'enrichissement SIRENE des structures NULL ou périmées.

    Critère de sélection (indépendant de tout flux source) :
        siret renseigné
        ET (denomination_sirene IS NULL
            OR last_sirene_enrich_at IS NULL
            OR last_sirene_enrich_at < CURRENT_DATE - <stale_months> mois)

    Tri `last_sirene_enrich_at ASC NULLS FIRST` + LIMIT : les jamais-enrichies
    passent en premier, puis les plus périmées ; le backlog se draine sur
    plusieurs runs sans dépasser le rate-limit INSEE (30 req/min).
    """
    params = kwargs.get("params") or {}
    db_conn_id = params.get("db_conn_id", "sonum-prod-db")
    batch_limit = int(params.get("batch_limit", 2000))
    stale_months = int(params.get("stale_months", 4))

    api_key_insee = Variable.get("API_SIRENE_TOKEN", default_var=None)
    if not api_key_insee:
        logging.warning(
            "Variable Airflow 'API_SIRENE_TOKEN' absente : rattrapage SIRENE ignoré."
        )
        return {"selectionnees": 0, "enrichies": 0}

    hook = PostgresHook(postgres_conn_id=db_conn_id)
    conn = hook.get_conn()
    cursor = conn.cursor()

    # --- 1) Sélection des structures à rattraper ---
    cursor.execute(
        """
        SELECT id, siret
        FROM main.structure_administrative
        WHERE deleted_at IS NULL
          AND siret IS NOT NULL
          AND btrim(siret) <> ''
          AND (
                denomination_sirene IS NULL
             OR last_sirene_enrich_at IS NULL
             OR last_sirene_enrich_at < (CURRENT_DATE - make_interval(months => %s))
          )
        ORDER BY last_sirene_enrich_at ASC NULLS FIRST, id ASC
        LIMIT %s
        """,
        (stale_months, batch_limit),
    )
    rows = cursor.fetchall()
    if not rows:
        logging.info("Aucune structure à rattraper.")
        cursor.close()
        conn.close()
        return {"selectionnees": 0, "enrichies": 0}

    df = pd.DataFrame(rows, columns=["id", "siret"])
    df["id"] = df["id"].astype(str)
    df["siret"] = df["siret"].astype(str)
    logging.info("%d structures sélectionnées pour rattrapage SIRENE.", len(df))

    # --- 2) Enrichissement SIRENE batch ---
    from etl.sirene_batch import SireneBatch
    from etl.source_capture import SIRENE_TABLE
    from etl.source_capture import make_source_sink

    # Capture brute du retour API SIRENE (couche source). Réutilise la connexion
    # courante ; le sink commit par lot, avant l'UPDATE final.
    source_sink = make_source_sink(conn, kwargs["run_id"], SIRENE_TABLE)

    sirene = SireneBatch(api_key=api_key_insee, source_sink=source_sink)
    df_sirene = sirene.enrichir_dataframe(df, colonne_id="id", colonne_siret="siret")
    df_sirene = df_sirene.astype(object).where(pd.notna(df_sirene), None)

    # --- 3) Silver : matérialisation de l'état transformé du run ---
    # staging.sirene__etablissements (V135), TRUNCATE + INSERT. L'étape
    # d'UPDATE ne lit plus le DataFrame en mémoire mais relit cette table
    # (base = interface, fiche 15).
    from psycopg2.extras import execute_values

    silver_rows = [
        (
            kwargs["run_id"],
            int(rec["id_source"]),
            rec["siret_sirene"],
            rec["etat_administratif"],
            rec["code_activite_principale"],
            rec["categorie_juridique"],
            rec["denomination_sirene"],
            rec["adresse_sirene"],
            rec["code_insee_sirene"],
            rec["code_postal_sirene"],
            rec["date_creation_sirene"],
            rec["tranche_effectifs_sirene"],
            bool(rec["sirene_trouve"]),
        )
        for _, rec in df_sirene.iterrows()
    ]
    cursor.execute("TRUNCATE staging.sirene__etablissements")
    if silver_rows:
        execute_values(
            cursor,
            "INSERT INTO staging.sirene__etablissements "
            f"(run_id, {', '.join(_SILVER_COLS)}) VALUES %s",
            silver_rows,
            page_size=1000,
        )
    else:
        logging.warning("Silver sirene : aucune ligne enrichie pour ce run.")
    conn.commit()
    logging.info(
        "%d lignes écrites dans staging.sirene__etablissements.", len(silver_rows)
    )

    # --- 4) Relecture du silver, filtrée sur run_id ---
    cursor.execute(
        f"SELECT {', '.join(_SILVER_COLS)} "
        "FROM staging.sirene__etablissements WHERE run_id = %s",
        (kwargs["run_id"],),
    )
    by_id = {}
    for row in cursor.fetchall():
        rec = dict(zip(_SILVER_COLS, row))
        by_id[str(rec["structure_id"])] = rec

    # --- 5) Construction des lignes d'UPDATE ---
    # On stamp `last_sirene_enrich_at` pour TOUTE ligne traitée (trouvée ou non) :
    # sinon les SIRET définitivement introuvables resteraient NULL et
    # monopoliseraient le quota `NULLS FIRST` à chaque run, empêchant le
    # backlog de se vider. Les colonnes de données restent en COALESCE côté
    # SQL (jamais écrasées par NULL).
    now_date = pendulum.now("UTC").date()
    update_rows = []
    nb_trouves = 0
    for sid in df["id"]:
        rec = by_id.get(sid, {})
        found = bool(rec.get("sirene_trouve"))
        if found:
            nb_trouves += 1
        update_rows.append(
            (
                rec.get("etat_administratif"),
                rec.get("code_activite_principale"),
                rec.get("categorie_juridique"),
                rec.get("denomination_sirene"),
                now_date,
                int(sid),
            )
        )

    # --- 6) UPDATE par id, en lots, dans une transaction ---
    try:
        for i in range(0, len(update_rows), _UPDATE_BATCH_SIZE):
            chunk = update_rows[i : i + _UPDATE_BATCH_SIZE]
            values_ph = ", ".join(["(%s, %s, %s, %s, %s, %s)"] * len(chunk))
            flat = [p for r in chunk for p in r]
            cursor.execute(
                f"""
                UPDATE main.structure_administrative AS s SET
                    etat_administratif       = COALESCE(v.etat, s.etat_administratif),
                    code_activite_principale = COALESCE(v.ape, s.code_activite_principale),
                    categorie_juridique      = COALESCE(v.cj, s.categorie_juridique),
                    denomination_sirene      = COALESCE(v.denom, s.denomination_sirene),
                    last_sirene_enrich_at    = v.ts
                FROM (VALUES {values_ph})
                    AS v(etat, ape, cj, denom, ts, struct_id)
                WHERE s.id = v.struct_id
                """,
                flat,
            )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()
        conn.close()

    logging.info(
        "Rattrapage SIRENE terminé : %d traitées, %d trouvées, %d sans donnée "
        "(re-stampées pour ne pas bloquer la file).",
        len(update_rows),
        nb_trouves,
        len(update_rows) - nb_trouves,
    )
    return {"selectionnees": len(update_rows), "enrichies": nb_trouves}


def valider_contrat_sirene(**kwargs):
    """Validation de contrat mode warn (fiche 02) : relit la capture brute
    du run dans source.sirene__etablissements et la confronte à
    contracts/sirene__etablissements.yml. Dead-end, jamais bloquant."""
    # Import lazy pour ne pas alourdir le parsing du DAG
    from etl.contrat_validation import valider_contrat_source

    valider_contrat_source(
        table="source.sirene__etablissements",
        contrat_nom="sirene__etablissements",
        db_conn_id=kwargs["params"]["db_conn_id"],
        run_id=kwargs["run_id"],
    )


with DAG(
    dag_id=DAG_ID,
    description=(
        "Rattrapage SIRENE : ré-enrichit les structures administratives avec "
        "SIRET dont denomination_sirene/last_sirene_enrich_at est NULL ou "
        "périmé, indépendamment des flux sources. Plafonné, plus anciens d'abord."
    ),
    default_args=DEFAULT_ARGS,
    start_date=START_DATE,
    schedule="0 4 * * *",
    dagrun_timeout=timedelta(minutes=180),
    on_success_callback=dag_success_callback,
    on_failure_callback=dag_failure_callback,
    catchup=False,
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            examples=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base PostgreSQL.",
        ),
        "batch_limit": Param(
            default=2000,
            type="integer",
            minimum=1,
            maximum=20000,
            title="Volume max par run",
            description=(
                "Nombre maximum de structures rattrapées par exécution "
                "(protège le rate-limit INSEE et le temps d'exécution)."
            ),
        ),
        "stale_months": Param(
            default=4,
            type="integer",
            minimum=1,
            maximum=60,
            title="Ancienneté avant ré-enrichissement (mois)",
            description=(
                "Une structure déjà enrichie est reprise si "
                "last_sirene_enrich_at est plus ancien que ce nombre de mois."
            ),
        ),
    },
    tags=["sirene", "backfill", "structure"],
) as dag:
    backfill_sirene_task = PythonOperator(
        task_id="backfill_sirene",
        python_callable=backfill_sirene,
    )

    valider_contrat_sirene_task = PythonOperator(
        task_id="valider_contrat_sirene",
        python_callable=valider_contrat_sirene,
    )

    # Validation de contrat (mode warn) en dead-end après la capture.
    backfill_sirene_task >> valider_contrat_sirene_task
