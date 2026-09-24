import datetime as datetime
import hashlib
import io
import json
import logging
import os
import re

import pandas as pd
import pendulum
import requests
from airflow import DAG
from airflow.decorators import task
from airflow.models import Variable
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import Param
from airflow.sdk import get_current_context
from airflow.utils.task_group import TaskGroup
from bs4 import BeautifulSoup
from psycopg2.extras import execute_values

from mattermost_notifier import MattermostNotifier

# === Notifier ===
# Récupérer les variables du Webhook
webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")

# Créer l'instance du notifier
notifier = MattermostNotifier(
    webhook_url=webhook,
    default_channel=channel,
)


# Définition des fonctions
def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")


# === Réglages ===
TZ = "Europe/Paris"
BASE_URL = "https://www.collectivites-locales.gouv.fr/cohesion-territoriale/france-ruralites-revitalisation"
DATA_DIR = "/tmp/tmp.zonage"
RAW_DIR = os.path.join(DATA_DIR, "raw")
STAMP = pendulum.now(TZ).to_date_string()
RAW_BASENAME = f"FRR_source_{STAMP}"

# Colonnes du silver staging.frr__zonage (V132), dans l'ordre produit par
# transform_zonage.
FRR_ZONAGE_COLS = ["code_insee", "type", "commentaire"]


DEFAULT_ARGS = {"owner": "airflow", "depends_on_past": False, "retries": None}

DAG_ID = "frr-dag-import"
START_DATE = pendulum.datetime(2025, 5, 1, tz="Europe/Paris")


def _hash_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()[:16]


# === DAG ===
with DAG(
    dag_id=DAG_ID,
    description="DAG import les données de zonage FRR.",
    default_args=DEFAULT_ARGS,
    start_date=START_DATE,
    dagrun_timeout=datetime.timedelta(minutes=900),
    schedule="0 2 1 * *",
    on_success_callback=dag_success_callback,
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
        "BASE_URL": BASE_URL,
        "DATA_DIR": DATA_DIR,
        "RAW_DIR": RAW_DIR,
    },
    catchup=False,
    tags=["admin", "etl", "fne", "frr", "qpv"],
) as dag:
    init_dir = BashOperator(
        task_id="init_working_dir",
        bash_command="""
            set -e
            rm -rf {{ params['DATA_DIR'] }} && mkdir -p {{ params['DATA_DIR'] }}/raw
        """,
    )

    cleanup_dir = BashOperator(
        task_id="cleanup_working_dir",
        bash_command="""
                    set -e
                    rm -rf {{ params['DATA_DIR'] }}
                """,
    )

    @task
    def find_download_url() -> str:
        """
        Récupère l’URL de téléchargement de la liste FRR/FRR+ depuis la page officielle.
        On cherche un lien .xlsx mentionnant 'Liste' et 'FRR'.
        """
        resp = requests.get(BASE_URL, timeout=60)
        resp.raise_for_status()

        soup = BeautifulSoup(resp.text, "html.parser")
        candidate = None
        for a in soup.find_all("a", href=True):
            href = a["href"]
            text = (a.get_text() or "").strip().lower()
            if href.lower().endswith(".xlsx") and (
                "frr" in href.lower() or "frr" in text
            ):
                # prioriser les libellés contenant "Liste" / "communes"
                if (
                    ("liste" in text)
                    or ("commune" in text)
                    or ("classement" in text)
                    or ("zonée" in text)
                    or ("zonées" in text)
                ):
                    candidate = href
                    break

        # fallback : 1er .xlsx contenant "frr"
        if not candidate:
            for a in soup.find_all("a", href=True):
                href = a["href"]
                if href.lower().endswith(".xlsx") and "frr" in href.lower():
                    candidate = href
                    break

        if not candidate:
            raise RuntimeError("Impossible de trouver le lien .xlsx FRR sur la page.")

        # Absolutiser si nécessaire
        if candidate.startswith("/"):
            candidate = "https://www.collectivites-locales.gouv.fr" + candidate

        return candidate

    @task
    def download_xlsx(url: str) -> str:
        """
        Télécharge le .xlsx et écrit une copie versionnée + une 'latest'.
        Retourne le chemin local du fichier .xlsx téléchargé.
        """
        r = requests.get(url, timeout=120)
        r.raise_for_status()
        content = r.content
        digest = _hash_bytes(content)

        versioned_path = os.path.join(RAW_DIR, f"{RAW_BASENAME}_{digest}.xlsx")
        latest_path = os.path.join(RAW_DIR, "FRR_latest.xlsx")

        with open(versioned_path, "wb") as f:
            f.write(content)
        with open(latest_path, "wb") as f:
            f.write(content)

        return latest_path  # on travaille toujours sur le dernier

    @task
    def transform_zonage(xlsx_path: str) -> None:
        """
        Transforme le XLSX en lignes de zonage écrites dans le silver
        staging.frr__zonage (V132, TRUNCATE + INSERT par run) :
        - code_insee de longueur 5
        - on enlève les 'Non classée'
        - colonnes finales: code_insee, type, commentaire
        - type forcé à 'FRR'
        """

        with open(xlsx_path, "rb") as f:
            data = f.read()
        df = pd.read_excel(io.BytesIO(data), dtype=str)

        # Normaliser colonnes
        cols = {c: c.strip() for c in df.columns}
        df.rename(columns=cols, inplace=True)

        # Colonne INSEE
        insee_candidates = [
            c for c in df.columns if re.search(r"code[\s_]*insee|insee", c, flags=re.I)
        ]
        if not insee_candidates:
            raise RuntimeError(
                f"Aucune colonne INSEE trouvée. Colonnes: {list(df.columns)}"
            )
        col_insee = insee_candidates[0]

        # Colonne classement / commentaire
        classement_candidates = [
            c
            for c in df.columns
            if re.search(r"classement|classsement|commentaire", c, flags=re.I)
        ]
        col_classement = classement_candidates[0] if classement_candidates else None
        if not col_classement:
            df["__commentaire__"] = None
            col_classement = "__commentaire__"

        # Nettoyage
        df[col_insee] = df[col_insee].astype(str).str.strip()
        df[col_classement] = df[col_classement].astype(str).str.strip()

        # Filtre
        filt = df[col_insee].str.len() == 5
        filt &= ~df[col_classement].fillna("").str.match(
            r"(?i)\s*Non\s*class(é|e)e?\s*$"
        )
        filtered_df = df.loc[filt].copy()

        filtered_df["code_insee"] = filtered_df[col_insee]
        filtered_df["commentaire"] = filtered_df[col_classement]
        filtered_df["type"] = "FRR"

        final_df = filtered_df[FRR_ZONAGE_COLS].copy()

        context = get_current_context()
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        try:
            with conn.cursor() as cursor:
                cursor.execute("TRUNCATE staging.frr__zonage")
                execute_values(
                    cursor,
                    "INSERT INTO staging.frr__zonage (run_id, code_insee, type, commentaire) VALUES %s",
                    [
                        [run_id] + [r[c] for c in FRR_ZONAGE_COLS]
                        for r in final_df.to_dict("records")
                    ],
                    page_size=1000,
                )
            conn.commit()
        finally:
            conn.close()

        logging.info("Silver staging.frr__zonage : %s lignes.", len(final_df))

    @task
    def write_to_source_frr(download_url: str) -> None:
        """Capture (dead-end) du zonage FRR transformé dans source.frr__zonage.

        Append-only, relit le silver staging.frr__zonage du run (mêmes records
        que l'ancien CSV filtré : valeurs str, absent = ''). source_key = URL
        de téléchargement.
        """
        context = get_current_context()
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT code_insee, type, commentaire FROM staging.frr__zonage WHERE run_id = %s",
                    (run_id,),
                )
                records = [
                    {c: (v if v is not None else "") for c, v in zip(FRR_ZONAGE_COLS, row)}
                    for row in cursor.fetchall()
                ]
        finally:
            conn.close()
        rows = [
            (run_id, download_url, json.dumps(record, ensure_ascii=False))
            for record in records
        ]
        if not rows:
            logging.info("[source] aucune ligne à capturer dans source.frr__zonage")
            return

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        with conn.cursor() as cursor:
            execute_values(
                cursor,
                "INSERT INTO source.frr__zonage (run_id, source_key, donnee) VALUES %s",
                rows,
            )
        conn.commit()
        logging.info(
            f"[source] {len(rows)} lignes insérées dans source.frr__zonage (run_id={run_id})"
        )

    @task
    def valider_contrat_frr() -> None:
        """Validation de contrat mode warn (fiche 02) : relit la capture brute
        du run dans source.frr__zonage et la confronte à
        contracts/frr__zonage.yml. Dead-end, jamais bloquant."""
        # Import lazy pour ne pas alourdir le parsing du DAG
        from etl.contrat_validation import valider_contrat_source

        context = get_current_context()
        valider_contrat_source(
            table="source.frr__zonage",
            contrat_nom="frr__zonage",
            db_conn_id=context["params"]["db_conn_id"],
            run_id=context["run_id"],
        )

    # Purge les zonages FRR existants avant réimport
    clean_frr_zonage = SQLExecuteQueryOperator(
        task_id="clean_frr_zonage",
        conn_id="{{ params['db_conn_id'] }}",
        sql="""
            DELETE
            FROM admin.zonage
            WHERE type ilike 'frr';
            """,
    )

    with TaskGroup(
        group_id="frr_zonage",
        tooltip="Import FRR – téléchargement, transformation, nettoyage",
        ui_color="#D9F2FF",
        ui_fgcolor="#1A1A1A",
    ) as frr_group:
        url = find_download_url()
        xlsx_local = download_xlsx(url)
        silver = transform_zonage(xlsx_local)
        source_task = write_to_source_frr(url)
        insert_into_db = SQLExecuteQueryOperator(
            task_id="insert_into_db",
            conn_id="{{ params['db_conn_id'] }}",
            sql="""
                INSERT INTO admin.zonage (code_insee, type, commentaire)
                SELECT code_insee, type, commentaire
                FROM staging.frr__zonage
                WHERE run_id = %(run_id)s;
            """,
            parameters={"run_id": "{{ run_id }}"},
        )

        # Capture en dead-end parallèle à clean_frr_zonage.
        url >> xlsx_local >> silver >> [source_task, clean_frr_zonage]
        clean_frr_zonage >> insert_into_db
        # Validation de contrat (mode warn) en dead-end après la capture.
        source_task >> valider_contrat_frr()

    init_dir >> frr_group >> cleanup_dir
