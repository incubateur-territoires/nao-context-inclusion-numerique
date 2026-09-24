import datetime as datetime
import json
import logging
import os
import zipfile
from pathlib import Path
from typing import Optional

import geopandas as gpd
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
from psycopg2.extras import execute_values
from shapely.geometry import MultiPolygon

from mattermost_notifier import MattermostNotifier

# Additional imports for SQL and Postgres


def _guess_epsg_from_filename(path: str) -> Optional[int]:
    """Fallback CRS inference based on filename hints (used only if GeoJSON has no CRS)."""
    name = Path(path).name.lower()
    if "wgs84" in name:
        return 4326
    if "lb93" in name or "lambert" in name:
        return 2154  # RGF93 / Lambert-93
    if "rgaf09" in name and "utm20n" in name:
        return 5490  # RGAF09 / UTM 20N
    if ("rgf95" in name or "rgfg95" in name) and "utm22n" in name:
        return 2972  # RGFG95 / UTM 22N (Guyane)
    if "rgr92" in name and "utm40s" in name:
        return 2975  # RGR92 / UTM 40S (La Réunion)
    if "rgm04" in name and "utm38s" in name:
        return 4471  # RGM04 / UTM 38S (Mayotte)
    return None


# === Notifier ===
webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")
notifier = MattermostNotifier(webhook_url=webhook, default_channel=channel)


def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")


# === Réglages ===
TZ = "Europe/Paris"
QPV_URL = (
    "https://www.data.gouv.fr/api/1/datasets/r/942d4ee8-8142-4556-8ea1-335537ce1119"
)
DATA_DIR = "/tmp/tmp.zonage_qpv"
RAW_DIR = os.path.join(DATA_DIR, "raw")
QPV_TARGET_GEOJSON_NAME = "QP2024_France_Hexagonale_Outre_Mer_WGS84.geojson"

DEFAULT_ARGS = {"owner": "airflow", "depends_on_past": False, "retries": None}
DAG_ID = "qpv-dag-import"

# Colonnes du silver staging.qpv__zonage (V133), dans l'ordre produit par
# transform_qpv.
QPV_ZONAGE_COLS = ["geom_wkt", "code", "libelle", "code_insee", "type", "source_file"]
START_DATE = pendulum.datetime(2025, 5, 1, tz="Europe/Paris")

with DAG(
    dag_id=DAG_ID,
    description="DAG import les données de zonage QPV (avec géométrie).",
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
        "QPV_URL": QPV_URL,
        "DATA_DIR": DATA_DIR,
        "RAW_DIR": RAW_DIR,
    },
    catchup=False,
    tags=["admin", "etl", "fne", "qpv"],
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
    def download_qpv_zip() -> str:
        """Télécharge le ZIP QPV et le stocke en RAW."""
        url = QPV_URL
        r = requests.get(
            url,
            timeout=180,
            allow_redirects=True,
            headers={"Accept": "application/zip,application/octet-stream,*/*;q=0.8"},
        )
        r.raise_for_status()

        # Si on a récupéré une page HTML (erreur/redirect), on stoppe.
        ctype = (r.headers.get("Content-Type") or "").lower()
        head = r.content[:200].lstrip()
        if "text/html" in ctype or head.startswith(b"<"):
            raise ValueError(
                "Le téléchargement QPV ne renvoie pas un ZIP (probablement une page HTML). "
                f"URL finale={r.url!r}, Content-Type={r.headers.get('Content-Type')!r}"
            )

        # Signature ZIP attendue: PK\x03\x04
        if not r.content.startswith(b"PK"):
            raise ValueError(
                "Le contenu téléchargé ne ressemble pas à un ZIP (signature 'PK' absente). "
                f"URL finale={r.url!r}, Content-Type={r.headers.get('Content-Type')!r}"
            )

        path = os.path.join(RAW_DIR, "qpv_latest.zip")
        with open(path, "wb") as f:
            f.write(r.content)
        return path

    @task
    def extract_qpv_zip(zip_path: str) -> list[str]:
        """Extrait le ZIP et retourne UNIQUEMENT le GeoJSON France+Outre-mer en WGS84."""
        extract_dir = os.path.join(RAW_DIR, "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        with zipfile.ZipFile(zip_path, "r") as z:
            z.extractall(extract_dir)

        # Le ZIP contient un dossier GEOJSON/
        geojson_root = Path(extract_dir) / "GEOJSON"
        search_root = geojson_root if geojson_root.exists() else Path(extract_dir)

        # Recherche exacte du fichier cible
        matches = list(search_root.rglob(QPV_TARGET_GEOJSON_NAME))
        if matches:
            return [str(matches[0])]

        # Fallback: recherche partout (au cas où la structure change)
        matches_anywhere = list(Path(extract_dir).rglob(QPV_TARGET_GEOJSON_NAME))
        if matches_anywhere:
            return [str(matches_anywhere[0])]

        # Diagnostic
        found = sorted([p.as_posix() for p in Path(extract_dir).rglob("*.geojson")])
        raise ValueError(
            "GeoJSON cible introuvable après extraction. "
            f"Attendu={QPV_TARGET_GEOJSON_NAME!r}. Exemples trouvés={found[:50]}"
        )

    @task
    def transform_qpv(geojson_paths: list[str]) -> None:
        """Lit tous les GeoJSON extraits, reprojette en EPSG:4326, garantit
        MultiPolygon, écrit le silver staging.qpv__zonage (V133, TRUNCATE +
        INSERT par run)."""

        def to_multipolygon(geom):
            if geom is None:
                return None
            gt = getattr(geom, "geom_type", None)
            if gt == "Polygon":
                return MultiPolygon([geom])
            return geom

        rows: list[dict] = []

        for geojson_path in geojson_paths:
            gdf = gpd.read_file(geojson_path)

            # Normalisation colonnes selon variantes
            rename_map = {}
            if "code_qp" in gdf.columns:
                rename_map["code_qp"] = "code"
            if "lib_qp" in gdf.columns:
                rename_map["lib_qp"] = "libelle"
            if "insee_com" in gdf.columns:
                rename_map["insee_com"] = "code_insee"
            gdf = gdf.rename(columns=rename_map)

            # CRS -> EPSG:4326
            if gdf.crs is None:
                epsg = _guess_epsg_from_filename(geojson_path)
                if epsg is not None:
                    gdf = gdf.set_crs(epsg)
            if gdf.crs is not None:
                # Evite de forcer inutilement si déjà en 4326
                try:
                    epsg_now = gdf.crs.to_epsg()
                except Exception:
                    epsg_now = None
                if epsg_now != 4326:
                    gdf = gdf.to_crs(4326)

            gdf["geometry"] = gdf["geometry"].apply(to_multipolygon)

            for _, row in gdf.iterrows():
                code_qpv = row.get("code")
                libelle = row.get("libelle")
                geom = row.get("geometry")

                raw_insee = (row.get("code_insee") or "").strip()
                codes = [c.strip() for c in raw_insee.split(",") if c.strip()] or [None]

                for c in codes:
                    rows.append(
                        {
                            "geom_wkt": geom.wkt if geom is not None else None,
                            "code": code_qpv,
                            "libelle": libelle,
                            "code_insee": c,
                            "type": "QPV",
                            "source_file": Path(geojson_path).name,
                        }
                    )

        context = get_current_context()
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        try:
            with conn.cursor() as cursor:
                cursor.execute("TRUNCATE staging.qpv__zonage")
                execute_values(
                    cursor,
                    "INSERT INTO staging.qpv__zonage "
                    "(run_id, geom_wkt, code, libelle, code_insee, type, source_file) VALUES %s",
                    [
                        [run_id] + [r[c] for c in QPV_ZONAGE_COLS]
                        for r in rows
                    ],
                    page_size=500,
                )
            conn.commit()
        finally:
            conn.close()

        logging.info("Silver staging.qpv__zonage : %s lignes.", len(rows))

    @task
    def write_to_source_qpv() -> None:
        """Capture (dead-end) du zonage QPV transformé dans source.qpv__zonage.

        Append-only, relit le silver staging.qpv__zonage du run (mêmes records
        que l'ancien CSV : valeurs str, absent = ''). source_key = URL de
        téléchargement QPV.
        """
        context = get_current_context()
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT geom_wkt, code, libelle, code_insee, type, source_file "
                    "FROM staging.qpv__zonage WHERE run_id = %s",
                    (run_id,),
                )
                records = [
                    {c: (v if v is not None else "") for c, v in zip(QPV_ZONAGE_COLS, row)}
                    for row in cursor.fetchall()
                ]
        finally:
            conn.close()
        rows = [
            (run_id, QPV_URL, json.dumps(record, ensure_ascii=False))
            for record in records
        ]
        if not rows:
            logging.info("[source] aucune ligne à capturer dans source.qpv__zonage")
            return

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        with conn.cursor() as cursor:
            execute_values(
                cursor,
                "INSERT INTO source.qpv__zonage (run_id, source_key, donnee) VALUES %s",
                rows,
            )
        conn.commit()
        logging.info(
            f"[source] {len(rows)} lignes insérées dans source.qpv__zonage (run_id={run_id})"
        )

    @task
    def valider_contrat_qpv() -> None:
        """Validation de contrat mode warn (fiche 02) : relit la capture brute
        du run dans source.qpv__zonage et la confronte à
        contracts/qpv__zonage.yml. Dead-end, jamais bloquant."""
        # Import lazy pour ne pas alourdir le parsing du DAG
        from etl.contrat_validation import valider_contrat_source

        context = get_current_context()
        valider_contrat_source(
            table="source.qpv__zonage",
            contrat_nom="qpv__zonage",
            db_conn_id=context["params"]["db_conn_id"],
            run_id=context["run_id"],
        )

    zip_local = download_qpv_zip()
    geojson_paths = extract_qpv_zip(zip_local)
    silver = transform_qpv(geojson_paths)
    source_task = write_to_source_qpv()
    # Validation de contrat (mode warn) en dead-end après la capture.
    source_task >> valider_contrat_qpv()

    insert_qpv = SQLExecuteQueryOperator(
        task_id="insert_qpv",
        conn_id="{{ params['db_conn_id'] }}",
        sql="""
        WITH src AS (
          SELECT
            ST_Multi(ST_GeomFromText(s.geom_wkt, 4326)) AS geom,
            s.code,
            s.libelle,
            s.code_insee AS code_insee_src,  -- valeur brute côté silver
            COALESCE(
              CASE WHEN c.code_insee IS NOT NULL THEN s.code_insee END,
              (
                SELECT c2.code_insee
                FROM admin.commune c2
                WHERE ST_Contains(c2.geom, ST_GeomFromText(s.geom_wkt, 4326))
                LIMIT 1
              )
            ) AS code_insee_final,
            'QPV'::text AS type
          FROM staging.qpv__zonage s
          LEFT JOIN admin.commune c ON c.code_insee = s.code_insee
          WHERE s.run_id = %(run_id)s
        )
        INSERT INTO admin.zonage (geom, code, libelle, code_insee, type)
        SELECT geom, code, libelle, code_insee_final, type
        FROM src
        WHERE code_insee_final IS NOT NULL
        ON CONFLICT (code, code_insee) DO NOTHING;
        """,
        parameters={"run_id": "{{ run_id }}"},
    )

    # init_dir AVANT le téléchargement (il écrit dans RAW_DIR) — le câblage
    # legacy laissait download_qpv_zip en racine parallèle de init_working_dir.
    init_dir >> zip_local
    silver >> [source_task, insert_qpv]
    insert_qpv >> cleanup_dir
