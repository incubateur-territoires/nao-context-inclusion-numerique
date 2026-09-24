import datetime
import logging

import pendulum
import requests
from airflow import DAG
from airflow.exceptions import AirflowSkipException
from airflow.models import Variable
from airflow.providers.standard.operators.python import PythonOperator
from airflow.sdk import Param

DEFAULT_CACHE_RESET_URL = (
    "https://cartographie.societenumerique.gouv.fr/api/cache/reset"
)

default_args = {
    "owner": "airflow",
    "retries": 3,
    "retry_delay": datetime.timedelta(minutes=2),
    "retry_exponential_backoff": True,
    "max_retry_delay": datetime.timedelta(minutes=15),
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


def dag_success_callback(context):
    _get_notifier().notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    _get_notifier().notify(context, "DAG", "FAILURE")


def reset_carto_cache(**context):
    """
    Appelle l'endpoint POST /api/cache/reset de la cartographie nationale
    pour invalider le cache (lieux + horaires + Next.js).

    - Token bearer : Variable Airflow `CARTO_CACHE_RESET_TOKEN`
    - URL : params.url (défaut Variable `CARTO_CACHE_RESET_URL`, puis défaut codé)
    - Si le token est vide → on skip (utile en dev/test où la carto n'est pas joignable).
    """
    params = context["params"]
    url = params.get("url") or Variable.get(
        "CARTO_CACHE_RESET_URL", default_var=DEFAULT_CACHE_RESET_URL
    )
    token = Variable.get("CARTO_CACHE_RESET_TOKEN", default_var="")

    if not token:
        raise AirflowSkipException(
            "CARTO_CACHE_RESET_TOKEN non défini — reset cache carto ignoré."
        )

    logging.info("Reset cache carto -> POST %s", url)
    response = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    response.raise_for_status()
    logging.info("Reset cache carto OK : %s", response.text)
    return response.text


with DAG(
    "carto-cache-reset",
    default_args=default_args,
    start_date=pendulum.datetime(2026, 5, 11, tz="UTC"),
    catchup=False,
    schedule=None,
    on_failure_callback=dag_failure_callback,
    on_success_callback=dag_success_callback,
    description=(
        "Invalide le cache de la cartographie nationale "
        "(https://cartographie.societenumerique.gouv.fr) en appelant "
        "POST /api/cache/reset. Déclenché par les DAGs de merge."
    ),
    params={
        "url": Param(
            None,
            type=["null", "string"],
            title="URL du endpoint de reset",
            description=(
                "Override optionnel de l'URL. Si null, on lit la Variable "
                "CARTO_CACHE_RESET_URL puis on retombe sur l'URL prod."
            ),
        ),
    },
    tags=["carto", "cache", "downstream"],
) as dag:
    reset_cache = PythonOperator(
        task_id="reset_carto_cache",
        python_callable=reset_carto_cache,
    )
