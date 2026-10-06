"""DAG carto-cache-reset-lieux-modifies — publie sur la cartographie nationale
les éditions de lieux faites dans MIN (ou par la double écriture coop).

Toutes les 10 min : s'il existe un lieu de main.lieu_inclusion modifié
(updated_at_min / updated_at_coop) depuis le dernier reset RÉUSSI du cache carto
— quel que soit son déclencheur —, déclenche `carto-cache-reset`. Sinon, rien.
Pas d'appel d'Airflow par MIN : la base est le seul point de rencontre.

Garde-fous contre les resets rapprochés :
- watermark partagé (etl/core/carto_cache.py) : un reset fait par coop-dag ou
  carto-dag-import couvre les éditions antérieures, pas de doublon ;
- pas de déclenchement si un run `carto-cache-reset` est déjà en file / en
  cours, ni moins de INTERVALLE_MINIMUM après le dernier reset (les éditions
  restent au-delà du watermark : rattrapées au tick suivant) ;
- `max_active_runs=1` ici et sur `carto-cache-reset`.

Sans watermark (premier déploiement, Variable effacée ou illisible) : un reset
est déclenché, sans condition. C'est le seul choix qui ne rate aucune édition
(on ignore depuis quand chercher) ; il coûte un reset, et le reset réussi pose
le watermark qui rétablit le régime normal.
"""

import logging
from datetime import timedelta

import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.python import ShortCircuitOperator
from airflow.providers.standard.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sdk import Param
from etl.core.carto_cache import lire_watermark
from etl.core.carto_cache import SQL_LIEU_MODIFIE_DEPUIS
from etl.core.carto_cache import trop_tot_pour_reset
from etl.core.carto_cache import VARIABLE_DERNIER_RESET

DAG_RESET = "carto-cache-reset"

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    # Le tick suivant (10 min) fait office de retry.
    "retries": 0,
}


def _get_notifier():
    """Lazy init du notifier pour éviter Variable.get() au top-level."""
    if not hasattr(_get_notifier, "_instance"):
        from mattermost_notifier import MattermostNotifier

        _get_notifier._instance = MattermostNotifier(
            webhook_url=Variable.get("MATTERMOST_WEBHOOK_URI"),
            default_channel=Variable.get("MATTERMOST_NOTIFICATION_CHANNEL"),
        )
    return _get_notifier._instance


def dag_failure_callback(context):
    _get_notifier().notify(context, "DAG", "FAILURE")


def detecter_lieux_modifies(**context):
    """True → déclencher le reset ; False → court-circuit (rien à publier)."""
    ti = context["ti"]
    en_attente = ti.get_dr_count(dag_id=DAG_RESET, states=["queued", "running"])
    if en_attente:
        logging.info(
            "%d run(s) %s déjà en file/en cours : rien à faire.", en_attente, DAG_RESET
        )
        return False

    brut = Variable.get(VARIABLE_DERNIER_RESET, default_var=None)
    watermark = lire_watermark(brut)
    if watermark is None:
        logging.warning(
            "Watermark %s absent ou illisible (%r) : reset déclenché sans condition.",
            VARIABLE_DERNIER_RESET,
            brut,
        )
        return True

    if trop_tot_pour_reset(watermark, pendulum.now("UTC")):
        logging.info(
            "Dernier reset à %s UTC, trop récent : report au tick suivant.", watermark
        )
        return False

    hook = PostgresHook(postgres_conn_id=context["params"]["db_conn_id"])
    modifie = (
        hook.get_first(SQL_LIEU_MODIFIE_DEPUIS, parameters={"depuis": watermark})
        is not None
    )
    logging.info(
        "Lieu modifié depuis le dernier reset (%s UTC) : %s", watermark, modifie
    )
    return modifie


with DAG(
    "carto-cache-reset-lieux-modifies",
    default_args=default_args,
    description=(
        "Toutes les 10 min : déclenche carto-cache-reset si un lieu d'inclusion "
        "a été modifié (MIN / coop) depuis le dernier reset réussi. Prod uniquement."
    ),
    schedule="*/10 * * * *",
    start_date=pendulum.datetime(2026, 9, 30, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    dagrun_timeout=timedelta(minutes=5),
    # Pas de callback de succès : 144 runs/jour, le canal serait noyé.
    on_failure_callback=dag_failure_callback,
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
    tags=["carto", "cache", "downstream"],
) as dag:
    # Invalidation du cache de la cartographie nationale : uniquement quand
    # l'exécution cible la base de production (même garde que coop-dag /
    # carto-dag-import) — placée en tête, aucune requête hors prod.
    check_prod_for_carto_cache_reset = ShortCircuitOperator(
        task_id="check_prod_for_carto_cache_reset",
        python_callable=lambda **ctx: ctx["params"]["db_conn_id"] == "sonum-prod-db",
    )
    detecter_lieux_modifies_task = ShortCircuitOperator(
        task_id="detecter_lieux_modifies",
        python_callable=detecter_lieux_modifies,
    )
    trigger_carto_cache_reset = TriggerDagRunOperator(
        task_id="trigger_carto_cache_reset",
        trigger_dag_id=DAG_RESET,
        reset_dag_run=True,
    )

    (
        check_prod_for_carto_cache_reset
        >> detecter_lieux_modifies_task
        >> trigger_carto_cache_reset
    )
