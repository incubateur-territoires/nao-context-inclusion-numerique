import logging
from datetime import timedelta

import pendulum
import requests
from airflow import DAG
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.standard.operators.python import (
    PythonOperator,
    ShortCircuitOperator,
)
from airflow.providers.standard.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sdk import Param
from airflow.task.trigger_rule import TriggerRule

from mattermost_notifier import MattermostNotifier

# ---------------------------------------------------------------------------
# Configuration des DAGs CI/CD schedulés
# ---------------------------------------------------------------------------
CICD_TARGETS = [
    {
        "dag_cible": "carto-dag-import",
        "schedule": "0 1 * * *",
        "tags": ["ci-cd", "validation", "carto"],
    },
    {
        "dag_cible": "aidants-connect-import",
        "schedule": "0 5 * * *",
        "tags": ["ci-cd", "validation", "aidants-connect"],
    },
    {
        "dag_cible": "coop-import",
        "schedule": "0 8 * * *",
        "tags": ["ci-cd", "validation", "coop"],
    },
    {
        "dag_cible": "schema-idPoste",
        "schedule": timedelta(weeks=2),
        "tags": ["ci-cd", "validation", "id-poste"],
        "start_date": pendulum.datetime(2024, 9, 4, 2, 0, tz="Europe/Paris"),
    },
]

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 0,
}


# ---------------------------------------------------------------------------
# Fonctions partagées (niveau module)
# ---------------------------------------------------------------------------
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


def _build_database_url(conn_id: str) -> str:
    """Construit l'URL psycopg2 depuis une connexion Airflow."""
    conn = PostgresHook.get_connection(conn_id)
    return f"postgresql://{conn.login}:{conn.password}@{conn.host}:{conn.port}/{conn.schema}"


def _snapshot_all(conn_id: str) -> dict:
    """Prend un snapshot des 3 rapports depuis la connexion Airflow."""
    from scripts.rapport_comptage import CollecteurComptage
    from scripts.rapport_personnes import CollecteurPersonnes
    from scripts.rapport_validation import CollecteurValidation

    database_url = _build_database_url(conn_id)
    result = {}

    collecteur_comptage = CollecteurComptage(database_url)
    try:
        collecteur_comptage.collecter()
        result["comptage"] = collecteur_comptage.to_snapshot()
    finally:
        collecteur_comptage.close()

    collecteur_personnes = CollecteurPersonnes(database_url)
    try:
        collecteur_personnes.collecter()
        result["personnes"] = collecteur_personnes.to_snapshot()
    finally:
        collecteur_personnes.close()

    collecteur_validation = CollecteurValidation(database_url)
    try:
        collecteur_validation.collecter()
        result["validation"] = collecteur_validation.to_snapshot()
    finally:
        collecteur_validation.close()

    return result


def snapshot_avant_fn(**kwargs):
    conn_id = (kwargs.get("params") or {}).get("db_conn_id", "sonum-test-db")
    snapshot = _snapshot_all(conn_id)
    kwargs["ti"].xcom_push(key="snapshot_avant", value=snapshot)
    logging.info(
        "Snapshot avant : comptage=%s tables, personnes=%s métriques, validation=%s métriques",
        len(snapshot["comptage"].get("comptages", [])),
        len(snapshot["personnes"].get("statistiques", [])),
        len(snapshot["validation"].get("validations", [])),
    )


def snapshot_apres_fn(**kwargs):
    conn_id = (kwargs.get("params") or {}).get("db_conn_id", "sonum-test-db")
    snapshot = _snapshot_all(conn_id)
    kwargs["ti"].xcom_push(key="snapshot_apres", value=snapshot)
    logging.info(
        "Snapshot après : comptage=%s tables, personnes=%s métriques, validation=%s métriques",
        len(snapshot["comptage"].get("comptages", [])),
        len(snapshot["personnes"].get("statistiques", [])),
        len(snapshot["validation"].get("validations", [])),
    )


def evaluer_fn(**kwargs):
    from scripts.rapport_comptage import Comptage, EvaluationComptage
    from scripts.rapport_personnes import EvaluationPersonnes, StatistiquePersonne
    from scripts.rapport_validation import EvaluationValidation, Validation

    ti = kwargs["ti"]
    params = kwargs.get("params") or {}
    seuil = float(params.get("seuil_tolerance", 3.0))

    snap_avant = ti.xcom_pull(task_ids="snapshot_avant", key="snapshot_avant")
    snap_apres = ti.xcom_pull(task_ids="snapshot_apres", key="snapshot_apres")

    if not snap_avant or not snap_apres:
        raise ValueError("Snapshots avant/après introuvables dans XCom")

    # --- Évaluation comptage ---
    avant_comptage = [
        Comptage.from_dict(c) for c in snap_avant["comptage"]["comptages"]
    ]
    apres_comptage = [
        Comptage.from_dict(c) for c in snap_apres["comptage"]["comptages"]
    ]
    res_comptage = EvaluationComptage(seuil_tolerance=seuil).evaluer(
        avant_comptage, apres_comptage
    )

    # --- Évaluation personnes ---
    avant_personnes = [
        StatistiquePersonne.from_dict(s)
        for s in snap_avant["personnes"]["statistiques"]
    ]
    apres_personnes = [
        StatistiquePersonne.from_dict(s)
        for s in snap_apres["personnes"]["statistiques"]
    ]
    res_personnes = EvaluationPersonnes(seuil_tolerance=seuil).evaluer(
        avant_personnes, apres_personnes
    )

    # --- Évaluation validation ---
    avant_validation = [
        Validation.from_dict(v) for v in snap_avant["validation"]["validations"]
    ]
    apres_validation = [
        Validation.from_dict(v) for v in snap_apres["validation"]["validations"]
    ]
    res_validation = EvaluationValidation(seuil_tolerance=seuil).evaluer(
        avant_validation, apres_validation
    )

    # --- Verdict global ---
    verdicts = [
        res_comptage.verdict_global,
        res_personnes.verdict_global,
        res_validation.verdict_global,
    ]
    verdict_global = "NOK" if "NOK" in verdicts else "OK"

    # --- Markdown combiné ---
    markdown = "\n\n---\n\n".join(
        [
            res_comptage.to_markdown(),
            res_personnes.to_markdown(),
            res_validation.to_markdown(),
        ]
    )

    ti.xcom_push(key="verdict", value=verdict_global)
    ti.xcom_push(key="evaluation_markdown", value=markdown)

    logging.info(
        "Verdict global : %s (comptage=%s, personnes=%s, validation=%s)",
        verdict_global,
        res_comptage.verdict_global,
        res_personnes.verdict_global,
        res_validation.verdict_global,
    )
    logging.info("=== Rapport d'évaluation ===\n%s", markdown)


def decide_deploy_prod_fn(**kwargs):
    params = kwargs.get("params") or {}
    auto_deploy = params.get("auto_deploy_prod", False)
    if not auto_deploy:
        logging.info("auto_deploy_prod=False, déploiement prod ignoré.")
        return False

    verdict = kwargs["ti"].xcom_pull(task_ids="evaluer", key="verdict")
    if verdict != "OK":
        logging.info("Verdict=%s, déploiement prod ignoré.", verdict)
        return False

    logging.info("Verdict OK + auto_deploy_prod=True → déploiement prod autorisé.")
    return True


def notifier_mattermost_fn(**kwargs):
    ti = kwargs["ti"]
    params = kwargs.get("params") or {}
    dag_cible = params.get("dag_cible", "inconnu")
    dag_run = kwargs.get("dag_run")

    webhook_url = Variable.get("MATTERMOST_WEBHOOK_URI")
    channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")

    verdict = ti.xcom_pull(task_ids="evaluer", key="verdict")
    markdown = ti.xcom_pull(task_ids="evaluer", key="evaluation_markdown")

    # Infos contextuelles
    triggered_by = getattr(dag_run, "triggered_by", None)
    triggered_by_label = triggered_by.value if triggered_by else "inconnu"
    run_id = dag_run.run_id if dag_run else "inconnu"
    db_conn_id = params.get("db_conn_id", "sonum-test-db")
    auto_deploy = params.get("auto_deploy_prod", False)

    entete = (
        f"| Champ | Valeur |\n"
        f"|:------|:-------|\n"
        f"| **DAG cible** | `{dag_cible}` |\n"
        f"| **Déclenché par** | `{triggered_by_label}` |\n"
        f"| **Run ID** | `{run_id}` |\n"
        f"| **Base de test** | `{db_conn_id}` |\n"
        f"| **Auto-deploy prod** | {'oui' if auto_deploy else 'non'} |\n"
    )

    # Construire le complément sur le déploiement prod
    deploy_info = ""
    if auto_deploy:
        if verdict == "OK":
            deploy_info = (
                "\n\n:rocket: **Déploiement prod** : "
                f"DAG `{dag_cible}` lancé sur `sonum-prod-db`."
            )
        else:
            deploy_info = (
                "\n\n:no_entry_sign: **Déploiement prod** : ignoré (verdict NOK)."
            )

    if markdown:
        icon = ":large_green_circle:" if verdict == "OK" else ":red_circle:"
        message = (
            f"**[CI/CD Orchestrator]** {icon} Verdict global : **{verdict}**\n\n"
            f"{entete}\n"
            f"{markdown}"
            f"{deploy_info}"
        )
    else:
        message = (
            f"**[CI/CD Orchestrator]**\n\n"
            f"{entete}\n"
            f":warning: Évaluation non disponible (tâches précédentes en échec).\n"
            f"Vérifiez le DAG run dans Airflow."
            f"{deploy_info}"
        )

    if "local" in (webhook_url, channel):
        logging.info("Mode local — notification Mattermost désactivée.")
        logging.info("=== Message Mattermost ===\n%s", message)
        return

    payload = {
        "text": message,
        "channel": channel,
        "username": "Airflow CI/CD",
    }

    response = requests.post(webhook_url, json=payload, timeout=30)
    if response.status_code != 200:
        logging.error("Erreur Mattermost (%s): %s", response.status_code, response.text)
    else:
        logging.info("Notification Mattermost envoyée (verdict=%s)", verdict)


# ---------------------------------------------------------------------------
# Factory : génère un DAG CI/CD complet
# ---------------------------------------------------------------------------
def _create_cicd_dag(
    dag_cible,
    schedule,
    tags,
    auto_deploy_default=True,
    dag_cible_enum=None,
    start_date=None,
):
    """Crée un DAG CI/CD complet pour un DAG cible donné.

    Si *dag_cible_enum* est fourni, le DAG est le sélecteur manuel
    (``ci-cd-orchestrator``) avec un Param enum. Sinon, c'est un DAG
    dédié ``ci-cd-<dag_cible>`` avec une valeur fixe.
    """
    if dag_cible_enum is not None:
        dag_id = "ci-cd-orchestrator"
        param_dag_cible = Param(
            default=dag_cible,
            type="string",
            enum=dag_cible_enum,
            title="DAG cible à tester",
            description="Identifiant du DAG d'import à exécuter sur la base de test.",
        )
    else:
        dag_id = f"ci-cd-{dag_cible}"
        param_dag_cible = Param(
            default=dag_cible,
            type="string",
            title="DAG cible à tester",
            description="Identifiant du DAG d'import à exécuter sur la base de test.",
        )

    if start_date is None:
        start_date = pendulum.datetime(2025, 1, 1, tz="Europe/Paris")

    dag = DAG(
        dag_id=dag_id,
        default_args=default_args,
        description=(
            "Orchestrateur CI/CD : restaure une copie prod, lance un DAG cible sur la base de test, "
            "puis compare les 3 rapports (comptage, personnes, validation) avant/après avec seuils de tolérance."
        ),
        schedule=schedule,
        dagrun_timeout=timedelta(hours=2),
        on_success_callback=dag_success_callback,
        on_failure_callback=dag_failure_callback,
        start_date=start_date,
        catchup=False,
        params={
            "dag_cible": param_dag_cible,
            "seuil_tolerance": Param(
                default=3.0,
                type="number",
                title="Seuil de tolérance (%)",
                description="Pourcentage maximum de diminution autorisée par table.",
            ),
            "db_conn_id": Param(
                default="sonum-test-db",
                type="string",
                enum=["sonum-test-db", "sonum-dev-db"],
                title="Connexion DB de test",
                description="Connexion Airflow pointant vers la base de test.",
            ),
            "auto_deploy_prod": Param(
                default=auto_deploy_default,
                type="boolean",
                title="Déployer en prod si OK",
                description="Si activé, déclenche automatiquement le DAG cible sur la base de prod après un verdict OK.",
            ),
        },
        tags=tags,
    )

    with dag:
        restore_backup = BashOperator(
            task_id="restore_backup",
            bash_command=" bash ${AIRFLOW_HOME}/dags/scripts/scw_restore_backup.sh ",
            env={
                "SCW_RDB_INSTANCE_ID": "{{ var.value.SCW_RDB_INSTANCE_ID }}",
                "SCW_ACCESS_KEY": "{{ var.value.SCW_ACCESS_KEY }}",
                "SCW_SECRET_KEY": "{{ var.value.SCW_SECRET_KEY }}",
                "SCW_DEFAULT_PROJECT_ID": "{{ var.value.SCW_DEFAULT_PROJECT_ID }}",
                "SCW_DEFAULT_ORGANIZATION_ID": "{{ var.value.SCW_DEFAULT_ORGANIZATION_ID }}",
                "SCW_RESTORE_DB_NAME": "dataspace_test",
                "SCW_POLL_INTERVAL": "30",
                "SCW_POLL_TIMEOUT": "1800",
                "GRANT_USERS": "{{ var.value.get('GRANT_USERS', '') }}",
            },
            append_env=True,
            execution_timeout=timedelta(minutes=45),
        )

        snapshot_avant = PythonOperator(
            task_id="snapshot_avant",
            python_callable=snapshot_avant_fn,
        )

        trigger_dag_cible = TriggerDagRunOperator(
            task_id="trigger_dag_cible",
            trigger_dag_id="{{ params.dag_cible }}",
            conf={
                "db_conn_id": "sonum-test-db",
            },
            wait_for_completion=True,
            poke_interval=60,
            reset_dag_run=True,
            execution_timeout=timedelta(hours=4),
        )

        snapshot_apres = PythonOperator(
            task_id="snapshot_apres",
            python_callable=snapshot_apres_fn,
        )

        evaluer = PythonOperator(
            task_id="evaluer",
            python_callable=evaluer_fn,
        )

        notifier_mattermost = PythonOperator(
            task_id="notifier_mattermost",
            python_callable=notifier_mattermost_fn,
            trigger_rule=TriggerRule.ALL_DONE,
        )

        decide_deploy_prod = ShortCircuitOperator(
            task_id="decide_deploy_prod",
            python_callable=decide_deploy_prod_fn,
            ignore_downstream_trigger_rules=False,
        )

        trigger_dag_prod = TriggerDagRunOperator(
            task_id="trigger_dag_prod",
            trigger_dag_id="{{ params.dag_cible }}",
            conf={
                "db_conn_id": "sonum-prod-db",
            },
            wait_for_completion=True,
            poke_interval=60,
            reset_dag_run=True,
            execution_timeout=timedelta(hours=4),
        )

        (
            restore_backup
            >> snapshot_avant
            >> trigger_dag_cible
            >> snapshot_apres
            >> evaluer
        )

        evaluer >> decide_deploy_prod >> trigger_dag_prod

        [evaluer, trigger_dag_prod] >> notifier_mattermost

    return dag


# ---------------------------------------------------------------------------
# Génération des DAGs
# ---------------------------------------------------------------------------

# 4 DAGs schedulés (auto_deploy_prod=True par défaut)
for _target in CICD_TARGETS:
    globals()[f"ci-cd-{_target['dag_cible']}"] = _create_cicd_dag(
        dag_cible=_target["dag_cible"],
        schedule=_target["schedule"],
        tags=_target["tags"],
        auto_deploy_default=True,
        start_date=_target.get("start_date"),
    )

# DAG manuel (auto_deploy_prod=False, schedule=None, enum)
globals()["ci-cd-orchestrator"] = _create_cicd_dag(
    dag_cible="coop-import",
    schedule=None,
    tags=["ci-cd", "validation", "orchestrator"],
    auto_deploy_default=False,
    dag_cible_enum=[
        "coop-import",
        "carto-dag-import",
        "schema-idPoste",
        "aidants-connect-import",
    ],
)
