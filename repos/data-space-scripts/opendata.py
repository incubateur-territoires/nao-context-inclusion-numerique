import datetime
import json
import os

import pendulum
import requests
from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import task, Param, Variable

from etl.database_utils import query_postgres
from mattermost_notifier import MattermostNotifier

# === Notifier ===
webhook = Variable.get("MATTERMOST_WEBHOOK_URI")
channel = Variable.get("MATTERMOST_NOTIFICATION_CHANNEL")
notifier = MattermostNotifier(webhook_url=webhook, default_channel=channel)


def dag_success_callback(context):
    notifier.notify(context, "DAG", "SUCCESS")


def dag_failure_callback(context):
    notifier.notify(context, "DAG", "FAILURE")


# === Réglages ===
DATA_DIR = "/tmp/tmp.opendata"

DEFAULT_ARGS = {"owner": "airflow", "depends_on_past": False, "retries": 1}
START_DATE = pendulum.datetime(2026, 4, 1, tz="Europe/Paris")

with DAG(
    dag_id="opendata-publication",
    description="DAG de publication des données des lieux en opendata",
    default_args=DEFAULT_ARGS,
    start_date=START_DATE,
    dagrun_timeout=datetime.timedelta(minutes=15),
    schedule="0 4 * * *",  # Chaque nuit à 4h
    on_success_callback=dag_success_callback,
    on_failure_callback=dag_failure_callback,
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
        "data_gouv_api_base_uri": Param(
            default="https://www.data.gouv.fr/api/1",
            type="string",
            title="URI de l'API",
            description="L'URI de l'API data.gouv.fr. Par défaut : https://www.data.gouv.fr/api/1, pour les tests : https://demo.data.gouv.fr/api/1",
        ),
        "dataset_id": Param(
            default="69c3ba7a9884d29f3b44f77d",
            type="string",
            title="Identifiant du jeu de données data.gouv.fr",
            description="L'ID ou le slug du dataset sur data.gouv.fr.",
        ),
        "mednum_resource_id": Param(
            default="320851b5-4ea6-467b-9142-3709400596fb",
            type="string",
            title="Identifiant de la ressource au format MedNum",
            description="Met à jour la ressource existante. ",
        ),
        "geojson_resource_id": Param(
            default="72ae4e77-656d-459a-a7c5-26a227fae90d",
            type="string",
            title="Identifiant de la ressource au format GeoJSON",
            description="Met à jour la ressource existante. ",
        ),
        "parquet_resource_id": Param(
            default="36514130-f248-45c5-9a48-0a92f0af5827",
            type="string",
            title="Identifiant de la ressource au format Parquet",
            description="Met à jour la ressource existante. ",
        ),
        "resource_title": Param(
            default="Lieux de médiation numérique",
            type="string",
            title="Titre de la ressource",
            description="Titre affiché sur data.gouv.fr pour cette ressource.",
        ),
        "resource_description": Param(
            default="Export automatique des lieux de médiation numérique visibles dans la cartographie nationale.",
            type="string",
            title="Description de la ressource",
            description="Description affichée sur data.gouv.fr pour cette ressource.",
        ),
        "filename": Param(
            default="lieux-mediation-numerique",
            type="string",
            title="Nom du fichier (sans l'extension)",
            description="Nom du fichier généré et envoyé sur data.gouv.fr.",
        ),
    },
    catchup=False,
    tags=["opendata", "publication", "data.gouv.fr", "lieux"],
) as dag:
    init_working_dir = BashOperator(
        task_id="init_working_dir",
        bash_command="""
            rm -rf """
        + DATA_DIR
        + """ && mkdir -p """
        + DATA_DIR
        + """
            if [[ $? -ne 0 ]]; then
                echo 'Error to drop or create the working directory!'
                exit 1
            fi
            """,
    )

    drop_working_dir = BashOperator(
        task_id="drop_working_dir",
        bash_command="""rm -rf """
        + DATA_DIR
        + """
            if [[ $? -ne 0 ]]; then
                echo 'Error to drop the working_dir !'
                exit 1
            fi""",
    )

    @task
    def export_format_mednum(**context) -> str:
        """Exécute la requête SQL et exporte le résultat en CSV dans un fichier temporaire."""
        params = context["params"]
        conn_id = params["db_conn_id"]
        filename = params["filename"] + ".csv"

        os.makedirs(DATA_DIR, exist_ok=True)
        csv_path = os.path.join(DATA_DIR, filename)

        df = query_postgres(
            query="SELECT * FROM opendata.lieux_mednum;", conn_id=conn_id
        )
        if df.empty:
            raise ValueError(
                "La requête SQL n'a retourné aucune ligne. Publication annulée."
            )

        df.to_csv(csv_path, index=False, sep=";", encoding="utf-8-sig")

        print(
            f"Export réussi : {len(df)} lignes, {len(df.columns)} colonnes → {csv_path}"
        )
        return csv_path

    @task
    def export_format_parquet(**context) -> str:
        """Exécute la requête SQL et exporte le résultat en Parquet dans un fichier temporaire."""
        params = context["params"]
        conn_id = params["db_conn_id"]
        filename = params["filename"] + ".parquet"

        os.makedirs(DATA_DIR, exist_ok=True)
        parquet_path = os.path.join(DATA_DIR, filename)

        df = query_postgres(
            query="SELECT * FROM opendata.lieux_mednum;", conn_id=conn_id
        )
        if df.empty:
            raise ValueError(
                "La requête SQL n'a retourné aucune ligne. Publication annulée."
            )

        df.to_parquet(parquet_path, index=False)

        print(
            f"Export Parquet réussi : {len(df)} lignes, {len(df.columns)} colonnes → {parquet_path}"
        )
        return parquet_path

    @task
    def export_format_geojson(**context) -> str:
        """Exécute la requête SQL et exporte le résultat en GeoJSON dans un fichier temporaire."""
        params = context["params"]
        conn_id = params["db_conn_id"]
        filename = params["filename"] + ".geojson"

        os.makedirs(DATA_DIR, exist_ok=True)
        geojson_path = os.path.join(DATA_DIR, filename)

        df = query_postgres(
            query="SELECT * FROM opendata.lieux_geojson;", conn_id=conn_id
        )
        if df.empty:
            raise ValueError(
                "La requête SQL n'a retourné aucune ligne. Publication annulée."
            )

        geojson_data = df.iloc[0, 0]
        if isinstance(geojson_data, str):
            geojson_data = json.loads(geojson_data)

        with open(geojson_path, "w", encoding="utf-8") as f:
            json.dump(geojson_data, f, ensure_ascii=False)

        print(f"Export GeoJSON réussi → {geojson_path}")
        return geojson_path

    @task
    def publish_file(
        file_path: str,
        extension: str,
        content_type: str,
        resource_id_key: str,
        resource_title_complement: str,
        **context,
    ) -> str:
        """Envoie le fichier sur data.gouv.fr : crée ou met à jour la ressource."""
        params = context["params"]
        data_gouv_api_base_uri = params["data_gouv_api_base_uri"]
        dataset_id = params["dataset_id"]
        resource_id = (params.get(resource_id_key) or "").strip()
        resource_title = params["resource_title"] + " - " + resource_title_complement
        resource_description = params["resource_description"]
        filename = params["filename"] + "." + extension
        filename_path = os.path.join(DATA_DIR, filename)

        if not dataset_id:
            raise ValueError("Le paramètre 'dataset_id' est obligatoire.")

        api_key = Variable.get("DATA_GOUV_API_KEY")
        headers = {"X-API-KEY": api_key}

        if resource_id:
            url_upload = f"{data_gouv_api_base_uri}/datasets/{dataset_id}/resources/{resource_id}/upload/"
            resp = requests.post(
                url_upload, files={"file": open(filename_path, "rb")}, headers=headers
            )
            resp.raise_for_status()

            print("Fichier mis à jour")

            url_meta = f"{data_gouv_api_base_uri}/datasets/{dataset_id}/resources/{resource_id}/"
            meta = {"title": resource_title, "description": resource_description}
            resp_meta = requests.put(url_meta, headers=headers, json=meta, timeout=30)
            resp_meta.raise_for_status()

            resource_url = resp_meta.json().get("url", "")
            print(f"Ressource mise à jour : {resource_id} → {resource_url}")
        else:
            url_upload = f"{data_gouv_api_base_uri}/datasets/{dataset_id}/upload/"
            resp = requests.post(
                url_upload, files={"file": open(filename_path, "rb")}, headers=headers
            )
            resp.raise_for_status()

            data = resp.json()
            new_resource_id = data.get("id", "")
            resource_url = data.get("url", "")

            if new_resource_id:
                url_meta = f"{data_gouv_api_base_uri}/datasets/{dataset_id}/resources/{new_resource_id}/"
                meta = {"title": resource_title, "description": resource_description}
                requests.put(
                    url_meta, headers=headers, json=meta, timeout=30
                ).raise_for_status()

            print(f"Nouvelle ressource créée : {new_resource_id} → {resource_url}")

        return resource_url

    # === Chaîne de dépendances ===
    export_mednum = export_format_mednum()
    publication_mednum = publish_file(
        export_mednum, "csv", "text/csv", "mednum_resource_id", "Format CSV Mednum"
    )

    export_geojson = export_format_geojson()
    publication_geojson = publish_file(
        export_geojson,
        "geojson",
        "application/vnd.geo+json",
        "geojson_resource_id",
        "Format GeoJSON",
    )

    export_parquet = export_format_parquet()
    publication_parquet = publish_file(
        export_parquet,
        "parquet",
        "application/octet-stream",
        "parquet_resource_id",
        "Format Parquet",
    )

    init_working_dir >> [export_mednum, export_geojson, export_parquet]
    export_mednum >> publication_mednum
    export_geojson >> publication_geojson
    export_parquet >> publication_parquet
    [publication_mednum, publication_geojson, publication_parquet] >> drop_working_dir
