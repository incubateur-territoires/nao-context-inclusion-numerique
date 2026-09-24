import datetime
import json
import logging
import os
import shutil

import pandas as pd
import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.amazon.aws.hooks.s3 import S3Hook
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.standard.operators.python import PythonOperator
from airflow.sdk import Param
from psycopg2.extras import execute_values

from etl.transform.ingest.postes_conum import dedup_rows_by_structure_tp_id
from etl.transform.ingest.postes_conum import main
from mattermost_notifier import MattermostNotifier

# === Constantes ===
CSV_SEPARATOR = ";"
EDITED_BY = "id-poste"
REFERENT_FONCTION = "Référent tableau de pilotage"
NON_RENSEIGNE = "Non renseigné"

# Colonnes des tables silver staging.idposte__* (V134), dans l'ordre produit
# par etl/transform/ingest/postes_conum.py (main).
IDPOSTE_SILVER_COLS = {
    "structure": [
        "structure_tp_id",
        "nom",
        "siret",
        "publique",
        "adresse",
        "code_insee",
        "code_postal",
        "contact",
    ],
    "poste": [
        "poste_conum_id",
        "structure_tp_id",
        "etat",
        "etat_instruction_v1",
        "etat_instruction_v2",
        "cn_pg_id",
        "date_attribution",
        "date_rendu_poste",
        "typologie",
        "origine_transfert",
        "poste_renouvele",
        "action_coselec",
    ],
    "personne": ["cn_pg_id", "structure_tp_id", "nom", "prenom", "contact"],
    "formation": [
        "personne_id_pg",
        "lot",
        "marche_formation",
        "label",
        "date_debut",
        "date_fin",
        "lieu",
        "parcours",
        "pix",
        "remn",
        "observations",
    ],
    "subvention": [
        "poste_id",
        "date_debut_convention_dgcl",
        "date_debut_financement_dgcl",
        "date_fin_convention_dgcl",
        "date_fin_financement_dgcl",
        "mois_utilises_periode_financement_dgcl",
        "date_debut_convention_ditp",
        "date_debut_financement_ditp",
        "date_fin_convention_ditp",
        "date_fin_financement_ditp",
        "mois_utilises_periode_financement_ditp",
        "date_debut_convention_dge",
        "date_debut_financement_dge",
        "date_fin_convention_dge",
        "date_fin_financement_dge",
        "mois_utilises_periode_financement_dge",
        "montant_subvention_v1",
        "montant_versement_v1",
        "montant_avoir_v1",
        "montant_bonification_v2",
        "montant_subvention_v2",
        "montant_avoir_v2",
        "versement_1_v2",
        "versement_2_v2",
        "versement_3_v2",
        "date_versement_1_v2",
        "date_versement_2_v2",
        "date_versement_3_v2",
    ],
    "contrat": [
        "cn_pg_id",
        "structure_tp_id",
        "date_debut",
        "date_fin",
        "date_rupture",
        "type",
    ],
}


def _read_silver(db_conn_id, table, run_id):
    """Lit staging.idposte__<table> du run en DataFrame de valeurs natives.

    Remplace les read_csv des anciens CSV du working_dir : les colonnes
    typées de staging (BIGINT/DATE/BOOLEAN/TEXT) redonnent des int/date/bool
    Python, iso avec l'inférence pandas du CSV — les lookups dict par id des
    lecteurs (personne_map, structure_map, poste_mapping) restent valides.
    dtype=object pour conserver les valeurs Python telles quelles (None
    compris) sans re-numpyfication.
    """
    cols = IDPOSTE_SILVER_COLS[table]
    hook = PostgresHook(postgres_conn_id=db_conn_id)
    conn = hook.get_conn()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                f"SELECT {', '.join(cols)} FROM staging.idposte__{table} WHERE run_id = %s",
                (run_id,),
            )
            rows = cursor.fetchall()
    finally:
        conn.close()
    return pd.DataFrame(rows, columns=cols, dtype=object)

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


default_args = {
    "owner": "airflow",
    "retries": 0,
}


with DAG(
    dag_id="schema-idPoste",
    default_args=default_args,
    schedule=None,
    start_date=pendulum.datetime(2024, 9, 4, 2, 0, tz="Europe/Paris"),
    catchup=False,
    on_failure_callback=dag_failure_callback,
    on_success_callback=dag_success_callback,
    tags=["inclusion-numerique", "id-poste"],
    dagrun_timeout=datetime.timedelta(minutes=1500),
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            examples=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
        "working_dir": "/tmp/tmp.8EE4C22C",
    },
) as dag:

    def download_from_s3(**context):
        local_file = "/opt/airflow/data/conum.csv"
        working_dir = context["params"]["working_dir"]
        output_path = f"{working_dir}/conum.csv"

        # Vérifier si le fichier existe localement
        if os.path.exists(local_file):
            logging.info(f"[✔] Fichier local détecté : {local_file}")
            shutil.copy(local_file, output_path)
            logging.info(f"[✔] Fichier copié vers : {output_path}")
            return local_file

        bucket = Variable.get("IDPOSTE_S3_BUCKET")

        hook = S3Hook(aws_conn_id="s3_idposte")
        keys = hook.list_keys(bucket_name=bucket)

        if not keys:
            raise FileNotFoundError(
                f"Aucun fichier trouvé dans le bucket S3 '{bucket}'."
            )

        # Récupérer le fichier le plus récent par date de dernière modification
        client = hook.get_conn()
        most_recent_key = None
        most_recent_date = None
        for key in keys:
            metadata = client.head_object(Bucket=bucket, Key=key)
            last_modified = metadata["LastModified"]
            if most_recent_date is None or last_modified > most_recent_date:
                most_recent_date = last_modified
                most_recent_key = key

        logging.info(
            f"[i] Fichier le plus récent : s3://{bucket}/{most_recent_key} ({most_recent_date})"
        )

        tmp_path = hook.download_file(
            key=most_recent_key,
            bucket_name=bucket,
            local_path=working_dir,
        )

        shutil.move(tmp_path, output_path)
        logging.info(f"[✔] Fichier téléchargé : {output_path}")
        return most_recent_key

    def write_to_source(**context):
        """Capture brute (dead-end) du conum.csv dans source.idposte__conum.

        Append-only, sans transformation. Un échec ne doit jamais bloquer l'aval.
        """
        working_dir = context["params"]["working_dir"]
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]
        input_file = f"{working_dir}/conum.csv"
        source_key = context["ti"].xcom_pull(task_ids="download_file") or ""

        data = pd.read_csv(
            input_file, sep=CSV_SEPARATOR, dtype=str, keep_default_na=False
        )
        rows = [
            (run_id, source_key, json.dumps(record, ensure_ascii=False))
            for record in data.to_dict("records")
        ]
        if not rows:
            logging.info("[source] aucune ligne à capturer dans source.idposte__conum")
            return

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        with conn.cursor() as cursor:
            execute_values(
                cursor,
                "INSERT INTO source.idposte__conum (run_id, source_key, donnee) VALUES %s",
                rows,
            )
        conn.commit()
        logging.info(
            f"[source] {len(rows)} lignes insérées dans source.idposte__conum (run_id={run_id})"
        )

    def valider_contrat_idposte(**context):
        """Validation de contrat mode warn (fiche 02) : relit la capture brute
        du run dans source.idposte__conum et la confronte à
        contracts/idposte__conum.yml. Dead-end, jamais bloquant."""
        # Import lazy pour ne pas alourdir le parsing du DAG
        from etl.contrat_validation import valider_contrat_source

        valider_contrat_source(
            table="source.idposte__conum",
            contrat_nom="idposte__conum",
            db_conn_id=context["params"]["db_conn_id"],
            run_id=context["run_id"],
        )

    def process_data_conum(**context):
        """Transforme conum.csv en 6 sous-flux écrits dans le silver
        staging.idposte__* (V134, TRUNCATE + INSERT par run)."""
        working_dir = context["params"]["working_dir"]
        db_conn_id = context["params"]["db_conn_id"]
        run_id = context["run_id"]
        input_file = f"{working_dir}/conum.csv"
        data = pd.read_csv(input_file, sep=CSV_SEPARATOR)
        logging.info(f"{len(data)} lignes chargées depuis conum.csv")
        tables = main(data)

        hook = PostgresHook(postgres_conn_id=db_conn_id)
        conn = hook.get_conn()
        try:
            with conn.cursor() as cursor:
                for table_name, cols in IDPOSTE_SILVER_COLS.items():
                    cursor.execute(f"TRUNCATE staging.idposte__{table_name}")
                    table_data = tables.get(table_name)
                    if table_data is None or table_data.empty:
                        logging.warning(
                            "Silver staging.idposte__%s : aucune ligne produite.",
                            table_name,
                        )
                        continue
                    # str() uniforme (les colonnes typées de staging castent le
                    # littéral) ; pd.isna couvre None / pd.NA / NaT.
                    rows = [
                        [run_id]
                        + [
                            None if pd.isna(record[c]) else str(record[c])
                            for c in cols
                        ]
                        for record in table_data.to_dict("records")
                    ]
                    execute_values(
                        cursor,
                        f"INSERT INTO staging.idposte__{table_name} (run_id, {', '.join(cols)}) VALUES %s",
                        rows,
                        page_size=1000,
                    )
                    logging.info(
                        "Silver staging.idposte__%s : %s lignes.",
                        table_name,
                        len(rows),
                    )
            conn.commit()
        finally:
            conn.close()

    def enrich_structures_caches(**context):
        """Enrichissement SIRENE + BAN des structures du run via les caches
        (staging.*__cache, V137) : cache-first, seuls les manquants/périmés
        partent à l'API (capture bronze source.* au passage) et les résultats
        utiles sont upsertés dans les caches. Plus aucun CSV enrichi : le
        lecteur process_enriched_structure rejoint silver ⋈ caches (lot 2)."""
        try:
            api_key = Variable.get("API_SIRENE_TOKEN")
            db_conn_id = context["params"]["db_conn_id"]

            df = _read_silver(db_conn_id, "structure", context["run_id"])
            if df.empty:
                logging.warning(
                    "staging.idposte__structure est vide. Aucun enrichissement."
                )
                return
            logging.info(f"{len(df)} structures à enrichir (cache-first).")

            from etl.enrichment_cache import GeocodeurAvecCache
            from etl.enrichment_cache import SireneAvecCache
            from etl.geocoding_batch import GeocodeurBatch
            from etl.quarantaine import make_rejets_sink
            from etl.sirene_batch import SireneBatch
            from etl.source_capture import BAN_TABLE
            from etl.source_capture import SIRENE_TABLE
            from etl.source_capture import make_source_sink

            # Même préparation que l'ex-chemin 'base' de structure_enrichment :
            # la clé du cache géocodage est l'adresse STRIPPÉE + code_insee.
            df["_row_id"] = df.index.astype(str)
            df["adresse_recherche"] = df["adresse"].apply(
                lambda x: str(x).strip() if pd.notna(x) else ""
            )

            source_conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
            try:
                sirene = SireneAvecCache(
                    source_conn,
                    context["run_id"],
                    SireneBatch(
                        api_key=api_key,
                        source_sink=make_source_sink(
                            source_conn, context["run_id"], SIRENE_TABLE
                        ),
                    ),
                )
                sirene.enrichir_dataframe(
                    df, colonne_id="_row_id", colonne_siret="siret"
                )

                geocodeur = GeocodeurAvecCache(
                    source_conn,
                    context["run_id"],
                    GeocodeurBatch(
                        source_sink=make_source_sink(
                            source_conn, context["run_id"], BAN_TABLE
                        )
                    ),
                    rejets_sink=make_rejets_sink(
                        source_conn, context["run_id"],
                        flux="idposte__structure", etape="enrichissement",
                    ),
                )
                geocodeur.geocoder_dataframe(
                    df,
                    colonne_id="_row_id",
                    colonne_adresse="adresse_recherche",
                    colonne_code_insee="code_insee",
                )
            finally:
                source_conn.close()

            logging.info("Caches d'enrichissement à jour pour le run.")

        except Exception as e:
            logging.error(f"Erreur lors de l'enrichissement des structures : {e}")
            raise

    def process_personne_upsert_file(**context):
        """Lit staging.idposte__personne et upsert des personnes dans main.personne en batch."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "personne", context["run_id"])

            if data.empty:
                logging.warning(
                    "staging.idposte__personne est vide. Aucune personne upsertée."
                )
                return

            # Filtrer les lignes sans cn_pg_id et dédupliquer
            data = data[data["cn_pg_id"].notna()].copy()
            if data.empty:
                logging.warning("Aucune ligne avec cn_pg_id valide.")
                return
            data = data.drop_duplicates(subset=["cn_pg_id"], keep="first")

            BATCH_SIZE = 500
            upsert_rows = []
            for _, row in data.iterrows():
                upsert_rows.append(
                    (
                        int(row["cn_pg_id"]),
                        None if pd.isna(row.get("nom")) else row.get("nom"),
                        None if pd.isna(row.get("prenom")) else row.get("prenom"),
                        None if pd.isna(row.get("contact")) else row.get("contact"),
                    )
                )

            for i in range(0, len(upsert_rows), BATCH_SIZE):
                chunk = upsert_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(
                    [f"(%s, %s, %s, %s, '{EDITED_BY}', TRUE, now())"] * len(chunk)
                )
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_upsert_personnes_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.personne (cn_pg_id, nom, prenom, contact, edited_by, is_mediateur, updated_at_idposte)
                        VALUES {values_ph}
                        ON CONFLICT (cn_pg_id)
                        DO UPDATE SET
                            nom = COALESCE(main.personne.nom, EXCLUDED.nom),
                            prenom = COALESCE(main.personne.prenom, EXCLUDED.prenom),
                            contact = COALESCE(main.personne.contact, '{{}}'::jsonb) || COALESCE(EXCLUDED.contact, '{{}}'::jsonb),
                            edited_by = '{EDITED_BY}',
                            is_mediateur = TRUE,
                            updated_at_idposte = EXCLUDED.updated_at_idposte
                        RETURNING id;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Upsert des personnes terminé : {len(upsert_rows)} personnes traitées."
            )
        except Exception as e:
            logging.error(f"Erreur lors de l'upsert des personnes : {e}")
            raise

    def process_personne_affectations_file(**context):
        """Lit staging.idposte__personne et insère les affectations en batch avec est_active calculé via contrat."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "personne", context["run_id"])

            if data.empty:
                logging.warning(
                    "staging.idposte__personne est vide. Aucune affectation insérée."
                )
                return

            # Filtrer les lignes sans cn_pg_id ou structure_tp_id
            data = data[
                data["cn_pg_id"].notna() & data["structure_tp_id"].notna()
            ].copy()
            if data.empty:
                logging.warning(
                    "Aucune ligne avec cn_pg_id et structure_tp_id valides."
                )
                return

            BATCH_SIZE = 500

            # 1) Batch lookup personne_ids
            cn_pg_ids = [int(v) for v in data["cn_pg_id"].unique().tolist()]
            personne_map = {}
            if cn_pg_ids:
                ph = ", ".join(["%s"] * len(cn_pg_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_personnes_aff",
                        conn_id=db_conn_id,
                        sql=f"SELECT cn_pg_id, id FROM main.personne WHERE cn_pg_id IN ({ph});",
                        parameters=tuple(cn_pg_ids),
                    ).execute(context=context)
                    or []
                )
                personne_map = {row[0]: row[1] for row in results}

            # 2) Batch lookup structure_ids
            structure_tp_ids = data["structure_tp_id"].unique().tolist()
            structure_map = {}
            if structure_tp_ids:
                ph = ", ".join(["%s"] * len(structure_tp_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_structures_aff",
                        conn_id=db_conn_id,
                        sql=f"SELECT structure_tp_id, id FROM main.structure_administrative WHERE structure_tp_id IN ({ph});",
                        parameters=tuple(structure_tp_ids),
                    ).execute(context=context)
                    or []
                )
                structure_map = {row[0]: row[1] for row in results}

            # 3) Préparer les paires (personne_id, structure_id) et dédupliquer
            aff_rows = []
            seen = set()
            skipped = 0
            for _, row in data.iterrows():
                personne_id = personne_map.get(int(row["cn_pg_id"]))
                if not personne_id:
                    skipped += 1
                    continue
                structure_id = structure_map.get(row["structure_tp_id"])
                if not structure_id:
                    skipped += 1
                    continue
                key = (personne_id, structure_id)
                if key in seen:
                    continue
                seen.add(key)
                aff_rows.append(key)

            # 4) Batch upsert affectations avec est_active calculé via LEFT JOIN contrat
            for i in range(0, len(aff_rows), BATCH_SIZE):
                chunk = aff_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(["(%s, %s)"] * len(chunk))
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_upsert_affectations_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.personne_affectations_emploi (personne_id, structure_administrative_id, source, est_active)
                        SELECT v.personne_id, v.structure_administrative_id, 'idposte',
                               CASE WHEN COUNT(c.id) > 0 THEN TRUE ELSE FALSE END
                        FROM (VALUES {values_ph}) AS v(personne_id, structure_administrative_id)
                        LEFT JOIN main.contrat c
                            ON c.personne_id = v.personne_id
                            AND c.structure_id = v.structure_administrative_id
                            AND c.date_rupture IS NULL
                        GROUP BY v.personne_id, v.structure_administrative_id
                        ON CONFLICT (personne_id, structure_administrative_id, source)
                        DO UPDATE SET est_active = EXCLUDED.est_active;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Insertion des affectations terminé : {len(aff_rows)} affectations traitées."
            )
            if skipped > 0:
                logging.warning(
                    f"{skipped} lignes ignorées (personne ou structure non trouvée)."
                )
        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des affectations : {e}")
            raise

    def process_poste_file(**context):
        """Lit staging.idposte__poste et insère les données en batch."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "poste", context["run_id"])

            BATCH_SIZE = 500

            # 1) Batch lookup personne_ids
            cn_pg_ids = []
            for _, row in data.iterrows():
                if "cn_pg_id" in row and not pd.isna(row["cn_pg_id"]):
                    try:
                        cn_pg_ids.append(int(row["cn_pg_id"]))
                    except Exception:
                        pass
            cn_pg_ids = list(set(cn_pg_ids))

            personne_map = {}
            if cn_pg_ids:
                ph = ", ".join(["%s"] * len(cn_pg_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_personnes_poste",
                        conn_id=db_conn_id,
                        sql=f"SELECT cn_pg_id, id FROM main.personne WHERE cn_pg_id IN ({ph});",
                        parameters=tuple(cn_pg_ids),
                    ).execute(context=context)
                    or []
                )
                personne_map = {row[0]: row[1] for row in results}

            # 2) Batch lookup structure_ids
            structure_tp_ids = (
                [v for v in data["structure_tp_id"].dropna().unique().tolist()]
                if "structure_tp_id" in data.columns
                else []
            )

            structure_map = {}
            if structure_tp_ids:
                ph = ", ".join(["%s"] * len(structure_tp_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_structures_poste",
                        conn_id=db_conn_id,
                        sql=f"SELECT structure_tp_id, id FROM main.structure_administrative WHERE structure_tp_id IN ({ph});",
                        parameters=tuple(structure_tp_ids),
                    ).execute(context=context)
                    or []
                )
                structure_map = {row[0]: row[1] for row in results}

            # 3) Préparer les lignes d'insertion
            insert_rows = []
            for _, row in data.iterrows():
                cn_pg_id_val = None
                if "cn_pg_id" in row and not pd.isna(row["cn_pg_id"]):
                    try:
                        cn_pg_id_val = int(row["cn_pg_id"])
                    except Exception:
                        pass
                personne_id = personne_map.get(cn_pg_id_val) if cn_pg_id_val else None

                structure_tp_id_val = None
                if "structure_tp_id" in row and not pd.isna(row["structure_tp_id"]):
                    structure_tp_id_val = row["structure_tp_id"]
                structure_id = (
                    structure_map.get(structure_tp_id_val)
                    if structure_tp_id_val
                    else None
                )

                if not personne_id:
                    logging.warning(
                        f"Aucune personne trouvée pour cn_pg_id={cn_pg_id_val} (poste_conum_id={row['poste_conum_id']}). Insertion avec personne_id=NULL."
                    )
                if not structure_id:
                    logging.warning(
                        f"Aucune structure trouvée pour structure_tp_id={structure_tp_id_val} (poste_conum_id={row['poste_conum_id']}). Insertion avec structure_id=NULL."
                    )

                insert_rows.append(
                    (
                        row["poste_conum_id"],
                        personne_id,
                        structure_id,
                        row["typologie"],
                        row["date_attribution"],
                        row["date_rendu_poste"],
                        row["poste_renouvele"],
                        row["action_coselec"],
                        None
                        if pd.isna(row["origine_transfert"])
                        else int(row["origine_transfert"]),
                        row["etat_instruction_v1"],
                        row["etat_instruction_v2"],
                        row["etat"],
                    )
                )

            # 4) Batch insert postes
            for i in range(0, len(insert_rows), BATCH_SIZE):
                chunk = insert_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(["(" + ", ".join(["%s"] * 12) + ")"] * len(chunk))
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_insert_postes_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.poste (
                            poste_conum_id, personne_id, structure_id, typologie,
                            date_attribution, date_rendu_poste, poste_renouvele,
                            action_coselec, origine_transfert,
                            etat_instruction_v1, etat_instruction_v2, etat)
                        VALUES {values_ph}
                        ON CONFLICT DO NOTHING;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Insertion des postes terminée : {len(insert_rows)} postes traités."
            )

        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des postes : {e}")
            raise

    def process_formation_file(**context):
        """Lit staging.idposte__formation et insère les données dans la base de données en batch."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "formation", context["run_id"])

            if data.empty:
                logging.warning(
                    "staging.idposte__formation est vide. Aucun enregistrement inséré."
                )
                return

            csv_columns = list(data.columns)
            db_columns = ["personne_id"] + [
                col for col in csv_columns if col != "personne_id_pg"
            ]
            non_pg_columns = [col for col in csv_columns if col != "personne_id_pg"]

            BATCH_SIZE = 500

            # 1) Batch lookup personne_ids
            pg_ids = [int(v) for v in data["personne_id_pg"].dropna().unique().tolist()]
            personne_map = {}
            if pg_ids:
                ph = ", ".join(["%s"] * len(pg_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_personnes_formation",
                        conn_id=db_conn_id,
                        sql=f"SELECT cn_pg_id, id FROM main.personne WHERE cn_pg_id IN ({ph});",
                        parameters=tuple(pg_ids),
                    ).execute(context=context)
                    or []
                )
                personne_map = {row[0]: row[1] for row in results}

            # 2) Préparer les lignes d'insertion
            insert_rows = []
            skipped = 0
            for _, row in data.iterrows():
                personne_id_pg = row["personne_id_pg"]
                if pd.isna(personne_id_pg):
                    skipped += 1
                    continue
                personne_id = personne_map.get(int(personne_id_pg))
                if not personne_id:
                    skipped += 1
                    continue

                insert_rows.append(
                    [personne_id]
                    + [
                        None if pd.isna(row[col]) else row[col]
                        for col in non_pg_columns
                    ]
                )

            # 3) Batch insert formations
            num_cols = len(db_columns)
            for i in range(0, len(insert_rows), BATCH_SIZE):
                chunk = insert_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(
                    ["(" + ", ".join(["%s"] * num_cols) + ")"] * len(chunk)
                )
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_insert_formations_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.formation ({", ".join(db_columns)})
                        VALUES {values_ph}
                        ON CONFLICT DO NOTHING;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Insertion des formations terminée : {len(insert_rows)} formations traitées."
            )
            if skipped > 0:
                logging.warning(f"{skipped} lignes ignorées (personne non trouvée).")

        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des formations : {e}")
            raise

    def process_subvention_file(**context):
        """Lit staging.idposte__subvention et insère les données dans la base de données en batch.
        Nouveau schéma : une ligne par poste avec colonnes spécifiques par source (DGCL, DITP, DGE)."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "subvention", context["run_id"])

            if data.empty:
                logging.warning(
                    "staging.idposte__subvention est vide. Aucun enregistrement inséré."
                )
                return

            # 1. Récupérer tous les poste_ids en une seule requête
            poste_conum_ids = data["poste_id"].unique().tolist()

            if not poste_conum_ids:
                logging.warning(
                    "Aucun poste_id trouvé dans staging.idposte__subvention."
                )
                return

            # Construire la requête pour récupérer tous les mappings poste_conum_id -> poste_id
            placeholders = ", ".join(["%s"] * len(poste_conum_ids))
            select_all_postes_task = SQLExecuteQueryOperator(
                task_id="select_all_postes_subvention",
                conn_id=db_conn_id,
                sql=f"SELECT poste_conum_id, id FROM main.poste WHERE poste_conum_id IN ({placeholders});",
                parameters=tuple(poste_conum_ids),
            )
            select_all_postes_result = select_all_postes_task.execute(context=context)

            # Créer un dictionnaire de mapping poste_conum_id -> poste_id
            poste_mapping = (
                {row[0]: row[1] for row in select_all_postes_result}
                if select_all_postes_result
                else {}
            )

            # 2. Préparer tous les paramètres pour l'insertion batch
            batch_parameters = []
            skipped_count = 0

            for _, row in data.iterrows():
                poste_conum_id = row["poste_id"]
                poste_id = poste_mapping.get(poste_conum_id)

                if not poste_id:
                    logging.warning(
                        f"Aucune correspondance trouvée pour poste_conum_id={poste_conum_id}. Ligne ignorée."
                    )
                    skipped_count += 1
                    continue

                batch_parameters.append(
                    [
                        poste_id,
                        # Dates DGCL
                        row["date_debut_convention_dgcl"],
                        row["date_debut_financement_dgcl"],
                        row["date_fin_convention_dgcl"],
                        row["date_fin_financement_dgcl"],
                        None
                        if pd.isna(row["mois_utilises_periode_financement_dgcl"])
                        else int(row["mois_utilises_periode_financement_dgcl"]),
                        # Dates DITP
                        row["date_debut_convention_ditp"],
                        row["date_debut_financement_ditp"],
                        row["date_fin_convention_ditp"],
                        row["date_fin_financement_ditp"],
                        None
                        if pd.isna(row["mois_utilises_periode_financement_ditp"])
                        else int(row["mois_utilises_periode_financement_ditp"]),
                        # Dates DGE
                        row["date_debut_convention_dge"],
                        row["date_debut_financement_dge"],
                        row["date_fin_convention_dge"],
                        row["date_fin_financement_dge"],
                        None
                        if pd.isna(row["mois_utilises_periode_financement_dge"])
                        else int(row["mois_utilises_periode_financement_dge"]),
                        # Montants V1
                        None
                        if pd.isna(row["montant_subvention_v1"])
                        else int(row["montant_subvention_v1"]),
                        None
                        if pd.isna(row["montant_versement_v1"])
                        else int(row["montant_versement_v1"]),
                        None
                        if pd.isna(row["montant_avoir_v1"])
                        else int(row["montant_avoir_v1"]),
                        # Montants V2
                        None
                        if pd.isna(row["montant_bonification_v2"])
                        else int(row["montant_bonification_v2"]),
                        None
                        if pd.isna(row["montant_subvention_v2"])
                        else int(row["montant_subvention_v2"]),
                        None
                        if pd.isna(row["montant_avoir_v2"])
                        else int(row["montant_avoir_v2"]),
                        # Versements V2
                        None
                        if pd.isna(row["versement_1_v2"])
                        else int(row["versement_1_v2"]),
                        None
                        if pd.isna(row["versement_2_v2"])
                        else int(row["versement_2_v2"]),
                        None
                        if pd.isna(row["versement_3_v2"])
                        else int(row["versement_3_v2"]),
                        row["date_versement_1_v2"],
                        row["date_versement_2_v2"],
                        row["date_versement_3_v2"],
                    ]
                )

            # 3. Insérer toutes les données en batch si on a des paramètres
            if batch_parameters:
                # Construire la requête INSERT avec VALUES multiples
                values_placeholders = "(" + ", ".join(["%s"] * 28) + ")"
                all_values = ", ".join([values_placeholders] * len(batch_parameters))

                # Aplatir la liste de paramètres
                flat_parameters = [
                    param for row_params in batch_parameters for param in row_params
                ]

                insert_batch_task = SQLExecuteQueryOperator(
                    task_id="insert_subventions_batch",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.subvention (
                            poste_id,
                            date_debut_convention_dgcl,
                            date_debut_financement_dgcl,
                            date_fin_convention_dgcl,
                            date_fin_financement_dgcl,
                            mois_utilises_periode_financement_dgcl,
                            date_debut_convention_ditp,
                            date_debut_financement_ditp,
                            date_fin_convention_ditp,
                            date_fin_financement_ditp,
                            mois_utilises_periode_financement_ditp,
                            date_debut_convention_dge,
                            date_debut_financement_dge,
                            date_fin_convention_dge,
                            date_fin_financement_dge,
                            mois_utilises_periode_financement_dge,
                            montant_subvention_v1,
                            montant_versement_v1,
                            montant_avoir_v1,
                            montant_bonification_v2,
                            montant_subvention_v2,
                            montant_avoir_v2,
                            versement_1_v2,
                            versement_2_v2,
                            versement_3_v2,
                            date_versement_1_v2,
                            date_versement_2_v2,
                            date_versement_3_v2
                        )
                        VALUES {all_values}
                    """,
                    parameters=flat_parameters,
                )
                insert_batch_task.execute(context=context)
                logging.info(
                    f"Insertion batch réussie : {len(batch_parameters)} subventions insérées."
                )

            if skipped_count > 0:
                logging.warning(f"{skipped_count} lignes ignorées (poste non trouvé).")

        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des subventions : {e}")
            raise

    def process_contrat_file(**context):
        """Lit staging.idposte__contrat et insère les contrats en batch."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            data = _read_silver(db_conn_id, "contrat", context["run_id"])

            if data.empty:
                logging.warning(
                    "staging.idposte__contrat est vide. Aucun contrat inséré."
                )
                return

            BATCH_SIZE = 500

            # 1) Batch lookup personne_ids
            cn_pg_ids = [int(v) for v in data["cn_pg_id"].dropna().unique().tolist()]
            personne_map = {}
            if cn_pg_ids:
                ph = ", ".join(["%s"] * len(cn_pg_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_personnes_contrat",
                        conn_id=db_conn_id,
                        sql=f"SELECT cn_pg_id, id FROM main.personne WHERE cn_pg_id IN ({ph});",
                        parameters=tuple(cn_pg_ids),
                    ).execute(context=context)
                    or []
                )
                personne_map = {row[0]: row[1] for row in results}

            # 2) Batch lookup structure_ids
            structure_tp_ids = data["structure_tp_id"].dropna().unique().tolist()
            structure_map = {}
            if structure_tp_ids:
                ph = ", ".join(["%s"] * len(structure_tp_ids))
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_structures_contrat",
                        conn_id=db_conn_id,
                        sql=f"SELECT structure_tp_id, id FROM main.structure_administrative WHERE structure_tp_id IN ({ph});",
                        parameters=tuple(structure_tp_ids),
                    ).execute(context=context)
                    or []
                )
                structure_map = {row[0]: row[1] for row in results}

            # 3) Préparer les lignes d'insertion
            insert_rows = []
            skipped = 0
            for _, row in data.iterrows():
                cn_pg_id = row.get("cn_pg_id")
                if pd.isna(cn_pg_id):
                    skipped += 1
                    continue
                personne_id = personne_map.get(int(cn_pg_id))
                if not personne_id:
                    skipped += 1
                    continue

                structure_id = structure_map.get(row.get("structure_tp_id"))
                if not structure_id:
                    skipped += 1
                    continue

                insert_rows.append(
                    (
                        personne_id,
                        None if pd.isna(row["date_debut"]) else row["date_debut"],
                        None if pd.isna(row["date_fin"]) else row["date_fin"],
                        None if pd.isna(row["date_rupture"]) else row["date_rupture"],
                        None if pd.isna(row["type"]) else row["type"],
                        structure_id,
                    )
                )

            # 4) Batch insert contrats
            for i in range(0, len(insert_rows), BATCH_SIZE):
                chunk = insert_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(["(%s, %s, %s, %s, %s, %s)"] * len(chunk))
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_insert_contrats_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.contrat (personne_id, date_debut, date_fin, date_rupture, type, structure_id)
                        VALUES {values_ph}
                        ON CONFLICT DO NOTHING;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Insertion des contrats terminée : {len(insert_rows)} contrats traités."
            )
            if skipped > 0:
                logging.warning(
                    f"{skipped} lignes ignorées (personne ou structure non trouvée)."
                )

        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des contrats : {e}")
            raise

    def process_enriched_structure(**context):
        """Lit staging.idposte__structure du run, le joint aux caches
        d'enrichissement (staging.*__cache, V137) et insère les données dans
        les tables adresse et structure en batch. Remplace la relecture de
        structure_enriched.csv (lot 2) — écart tracé : les géocodages
        invalides (score < 0.5) ne sont plus consommés."""
        try:
            db_conn_id = context["params"]["db_conn_id"]

            from etl.core.enrichissement import normaliser_siret
            from etl.core.enrichissement import siret_valide
            from etl.core.idposte import cle_geocodage_structure
            from etl.core.idposte import consolider_structures
            from etl.enrichment_cache import lire_cache_geocodage
            from etl.enrichment_cache import lire_cache_sirene

            df_silver = _read_silver(db_conn_id, "structure", context["run_id"])
            if df_silver.empty:
                logging.warning(
                    "staging.idposte__structure est vide. Aucun enregistrement inséré."
                )
                return
            lignes = df_silver.to_dict(orient="records")

            sirets = [
                s
                for s in (normaliser_siret(ligne.get("siret")) for ligne in lignes)
                if siret_valide(s)
            ]
            cles_geo = [
                c for c in (cle_geocodage_structure(ligne) for ligne in lignes) if c
            ]

            cache_conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
            try:
                hits_sirene = lire_cache_sirene(cache_conn, sirets)
                hits_geo = lire_cache_geocodage(cache_conn, cles_geo)
            finally:
                cache_conn.close()
            logging.info(
                "Jointure silver ⋈ caches : %s lignes, %s hits SIRENE, %s hits géocodage.",
                len(lignes),
                len(hits_sirene),
                len(hits_geo),
            )

            data = pd.DataFrame(
                consolider_structures(lignes, hits_sirene, hits_geo)
            ).replace({pd.NA: None, "nan": None})

            if data.empty:
                logging.warning("Aucune structure consolidée. Aucun enregistrement inséré.")
                return

            def _is_blank(v):
                return (
                    v is None or (isinstance(v, str) and v.strip() == "") or pd.isna(v)
                )

            data = data[
                ~data["nom_voie"].apply(_is_blank)
                & ~data["code_insee"].apply(_is_blank)
                & ~data["code_postal"].apply(_is_blank)
            ].copy()

            if data.empty:
                logging.warning("Aucune ligne avec adresse valide.")
                return

            BATCH_SIZE = 500
            adresse_columns = [
                "clef_interop",
                "code_postal",
                "nom_commune",
                "nom_voie",
                "numero_voie",
                "geom",
                "code_insee",
                "repetition",
                "code_ban",
            ]
            # NB : "nom" retiré depuis la refonte 2026-05 — n'existe plus sur
            # structure_administrative. L'identité passe par denomination_sirene.
            # Si MIN attend un "nom" d'employeuse, utiliser denomination_sirene.
            structure_columns = [
                "structure_tp_id",
                "siret",
                "publique",
                "contact",
                "etat_administratif",
                "code_activite_principale",
                "categorie_juridique",
                "denomination_sirene",
            ]

            def _fmt_adresse(val, col):
                if val is None or pd.isna(val):
                    return None
                if col in ("code_insee", "code_postal"):
                    return str(val).zfill(5) if str(val).isdigit() else str(val)
                if col == "numero_voie":
                    return int(val)
                return val

            def _fmt_structure(val, col):
                if val is None or pd.isna(val):
                    return None
                if col == "siret":
                    return str(int(val)).zfill(14)
                if col == "categorie_juridique":
                    return str(val)[:4]
                return val

            # === Étape 1 : Batch upsert des adresses (dédupliquées par clé composite) ===
            adresse_data = data.drop_duplicates(
                subset=[
                    "code_postal",
                    "nom_commune",
                    "nom_voie",
                    "numero_voie",
                    "repetition",
                ],
                keep="first",
            ).copy()

            # Piège multi-ukey (cf CLAUDE.md) : main.adresse porte AUSSI
            # adresse_code_ban_ukey UNIQUE(code_ban), que l'ON CONFLICT composite
            # ci-dessous ne couvre pas. Quand la BAN fait évoluer le libellé d'une
            # adresse (même code_ban, clé composite différente), l'INSERT violait
            # la contrainte (vécu : run 2026-07-30, code_ban 3650e25c…, Nîmes).
            # On neutralise le code_ban entrant s'il est déjà porté en base ou
            # plus haut dans le batch : l'adresse s'insère/s'update sans lui, et
            # la résolution d'adresse_id (étape 2, lookup par code_ban) retombe
            # sur la ligne existante porteuse du code_ban.
            code_bans_batch = adresse_data["code_ban"].dropna().unique().tolist()
            code_bans_existants = set()
            if code_bans_batch:
                rows_existants = (
                    SQLExecuteQueryOperator(
                        task_id="lookup_code_bans_existants",
                        conn_id=db_conn_id,
                        sql=(
                            "SELECT code_ban::text FROM main.adresse WHERE code_ban IN "
                            f"({', '.join(['%s'] * len(code_bans_batch))});"
                        ),
                        parameters=tuple(code_bans_batch),
                    ).execute(context=context)
                    or []
                )
                code_bans_existants = {r[0] for r in rows_existants}
            a_neutraliser = adresse_data["code_ban"].notna() & (
                adresse_data["code_ban"].isin(code_bans_existants)
                | adresse_data["code_ban"].duplicated(keep="first")
            )
            if a_neutraliser.any():
                logging.info(
                    "%s code_ban neutralisés avant l'upsert adresse "
                    "(déjà portés en base ou en doublon dans le batch).",
                    int(a_neutraliser.sum()),
                )
                adresse_data.loc[a_neutraliser, "code_ban"] = None

            adresse_rows = []
            for _, row in adresse_data.iterrows():
                adresse_rows.append(
                    [_fmt_adresse(row.get(col), col) for col in adresse_columns]
                )

            for i in range(0, len(adresse_rows), BATCH_SIZE):
                chunk = adresse_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(
                    ["(" + ", ".join(["%s"] * len(adresse_columns)) + ")"] * len(chunk)
                )
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_upsert_adresses_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.adresse ({", ".join(adresse_columns)})
                        VALUES {values_ph}
                        ON CONFLICT (
                            code_postal, nom_commune, nom_voie,
                            (COALESCE(numero_voie::integer, 0)),
                            (COALESCE(repetition, ''::character varying))
                        )
                        DO UPDATE SET
                            code_ban = COALESCE(main.adresse.code_ban, EXCLUDED.code_ban),
                            clef_interop = COALESCE(main.adresse.clef_interop, EXCLUDED.clef_interop),
                            geom = COALESCE(main.adresse.geom, EXCLUDED.geom);
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(f"{len(adresse_rows)} adresses upsertées en batch.")

            # === Étape 2 : Récupérer les adresse_ids par code_ban / clef_interop ===
            code_bans = [v for v in data["code_ban"].dropna().unique().tolist()]
            clef_interops = [v for v in data["clef_interop"].dropna().unique().tolist()]

            lookup_conditions = []
            lookup_params = []
            if code_bans:
                lookup_conditions.append(
                    f"code_ban IN ({', '.join(['%s'] * len(code_bans))})"
                )
                lookup_params.extend(code_bans)
            if clef_interops:
                lookup_conditions.append(
                    f"clef_interop IN ({', '.join(['%s'] * len(clef_interops))})"
                )
                lookup_params.extend(clef_interops)

            adresse_by_ban = {}
            adresse_by_clef = {}
            if lookup_conditions:
                results = (
                    SQLExecuteQueryOperator(
                        task_id="batch_lookup_adresse_ids",
                        conn_id=db_conn_id,
                        sql=f"SELECT id, code_ban, clef_interop FROM main.adresse WHERE {' OR '.join(lookup_conditions)};",
                        parameters=tuple(lookup_params),
                    ).execute(context=context)
                    or []
                )

                for aid, cb, ci in results:
                    if cb:
                        adresse_by_ban[cb] = aid
                    if ci:
                        adresse_by_clef[ci] = aid

            def _resolve_adresse_id(row):
                cb = row.get("code_ban")
                if cb and not pd.isna(cb) and cb in adresse_by_ban:
                    return adresse_by_ban[cb]
                ci = row.get("clef_interop")
                if ci and not pd.isna(ci) and ci in adresse_by_clef:
                    return adresse_by_clef[ci]
                return None

            # === Étape 3 : Batch update structures (rattachement sans structure_tp_id) ===
            # Dédup par structure_tp_id imposée par UNIQUE(structure_tp_id) sur
            # main.structure_administrative — voir docs/id-poste-regles.md.
            update_rows = []
            for row in dedup_rows_by_structure_tp_id(r for _, r in data.iterrows()):
                adresse_id = _resolve_adresse_id(row)
                if not adresse_id:
                    continue
                update_rows.append(
                    (
                        row.get("structure_tp_id"),
                        adresse_id,
                        _fmt_structure(
                            row.get("etat_administratif"), "etat_administratif"
                        ),
                        _fmt_structure(
                            row.get("code_activite_principale"),
                            "code_activite_principale",
                        ),
                        _fmt_structure(
                            row.get("categorie_juridique"), "categorie_juridique"
                        ),
                        _fmt_structure(
                            row.get("denomination_sirene"), "denomination_sirene"
                        ),
                        _fmt_structure(row.get("siret"), "siret"),
                        row.get("nom"),
                        adresse_id,
                    )
                )

            for i in range(0, len(update_rows), BATCH_SIZE):
                chunk = update_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(
                    ["(%s, %s, %s, %s, %s, %s, %s, %s, %s)"] * len(chunk)
                )
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_update_structures_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        UPDATE main.structure_administrative AS s
                        SET structure_tp_id = v.new_tp_id,
                            adresse_id = v.new_adresse_id,
                            etat_administratif = COALESCE(v.etat_admin, s.etat_administratif),
                            code_activite_principale = COALESCE(v.cap, s.code_activite_principale),
                            categorie_juridique = COALESCE(v.cj, s.categorie_juridique),
                            denomination_sirene = COALESCE(v.ds, s.denomination_sirene),
                            edited_by = '{EDITED_BY}'
                        FROM (VALUES {values_ph})
                            AS v(new_tp_id, new_adresse_id, etat_admin, cap, cj, ds, match_siret, match_nom, match_adresse_id)
                        WHERE s.id = (
                              -- Un seul structure_tp_id par ligne physique :
                              -- UNIQUE(structure_tp_id). Plusieurs antennes peuvent
                              -- partager (siret, adresse_id) avec tp_id NULL (réseaux
                              -- co-localisés, doublons V073, géocodage AC sur le siège).
                              -- On rattache à l'antenne dont le nom ressemble le plus
                              -- au nom id-poste (match_nom) ; le siège (antenne NULL)
                              -- est scoré sur denomination_sirene. Voir docs/id-poste-regles.md §4.
                              SELECT s3.id
                              FROM main.structure_administrative s3
                              WHERE s3.siret = v.match_siret
                                AND s3.adresse_id IS NOT DISTINCT FROM v.match_adresse_id
                                AND s3.structure_tp_id IS NULL
                                AND s3.deleted_at IS NULL
                              ORDER BY (CASE WHEN s3.denomination_antenne IS NULL
                                             THEN similarity(lower(coalesce(s3.denomination_sirene, '')), lower(v.match_nom))
                                             ELSE similarity(lower(s3.denomination_antenne), lower(v.match_nom)) END) DESC,
                                       (s3.denomination_antenne IS NULL) DESC,
                                       s3.id
                              LIMIT 1
                          )
                          AND NOT EXISTS (
                              SELECT 1 FROM main.structure_administrative s2
                              WHERE s2.structure_tp_id = v.new_tp_id
                          );
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Batch update structures : {len(update_rows)} candidats traités."
            )

            # === Étape 4 : Batch insert structures (dédupliquées par structure_tp_id) ===
            insert_rows = []
            for row in dedup_rows_by_structure_tp_id(r for _, r in data.iterrows()):
                adresse_id = _resolve_adresse_id(row)
                if not adresse_id:
                    continue
                insert_rows.append(
                    [adresse_id]
                    + [_fmt_structure(row.get(col), col) for col in structure_columns]
                )

            num_cols = len(structure_columns) + 1
            for i in range(0, len(insert_rows), BATCH_SIZE):
                chunk = insert_rows[i : i + BATCH_SIZE]
                values_ph = ", ".join(
                    ["(" + ", ".join(["%s"] * num_cols) + f", '{EDITED_BY}')"]
                    * len(chunk)
                )
                flat_params = [p for r in chunk for p in r]
                SQLExecuteQueryOperator(
                    task_id=f"batch_insert_structures_{i}",
                    conn_id=db_conn_id,
                    sql=f"""
                        INSERT INTO main.structure_administrative (adresse_id, {", ".join(structure_columns)}, edited_by)
                        VALUES {values_ph}
                        ON CONFLICT DO NOTHING;
                    """,
                    parameters=flat_params,
                ).execute(context=context)

            logging.info(
                f"Batch insert structures : {len(insert_rows)} candidats traités."
            )

            # === Étape 5 : Synchroniser les contacts en batch ===
            # 5a: Collecter et dédupliquer les contacts
            contact_data = []  # (email, nom, prenom, telephone, structure_tp_id)
            for _, row in data.iterrows():
                contact_raw = row.get("contact")
                s_tp_id = row.get("structure_tp_id")
                if not contact_raw or pd.isna(contact_raw):
                    continue
                try:
                    contact_json = (
                        json.loads(contact_raw)
                        if isinstance(contact_raw, str)
                        else contact_raw
                    )
                except (json.JSONDecodeError, TypeError):
                    continue
                if not isinstance(contact_json, dict):
                    continue
                c_nom = contact_json.get("nom")
                c_prenom = contact_json.get("prenom")
                courriels = contact_json.get("courriels") or {}
                c_email = (
                    courriels.get("mail_gestionnaire")
                    if isinstance(courriels, dict)
                    else None
                )
                c_telephone = contact_json.get("telephone") or ""
                if not c_email:
                    continue
                contact_data.append(
                    (
                        c_email,
                        c_nom or NON_RENSEIGNE,
                        c_prenom or NON_RENSEIGNE,
                        c_telephone,
                        s_tp_id,
                    )
                )

            if contact_data:
                # 5b: Dédupliquer par (email, nom, prenom) et batch insert des nouveaux contacts
                unique_contacts = {}
                for email, nom, prenom, telephone, _ in contact_data:
                    key = (email, nom, prenom)
                    if key not in unique_contacts:
                        unique_contacts[key] = telephone

                contact_values = list(unique_contacts.items())
                for i in range(0, len(contact_values), BATCH_SIZE):
                    chunk = contact_values[i : i + BATCH_SIZE]
                    values_ph = ", ".join(["(%s, %s, %s, %s)"] * len(chunk))
                    flat_params = []
                    for (email, nom, prenom), telephone in chunk:
                        flat_params.extend([nom, prenom, email, telephone])
                    SQLExecuteQueryOperator(
                        task_id=f"batch_insert_contacts_{i}",
                        conn_id=db_conn_id,
                        sql=f"""
                            INSERT INTO main.contact (nom, prenom, email, telephone, fonction)
                            SELECT v.nom, v.prenom, v.email, v.telephone, '{REFERENT_FONCTION}'
                            FROM (VALUES {values_ph}) AS v(nom, prenom, email, telephone)
                            WHERE NOT EXISTS (
                                SELECT 1 FROM main.contact c
                                WHERE c.email = v.email AND c.nom = v.nom AND c.prenom = v.prenom
                                  AND c.fonction = '{REFERENT_FONCTION}'
                            );
                        """,
                        parameters=flat_params,
                    ).execute(context=context)

                # 5c: Récupérer les IDs de tous les contacts
                lookup_keys = list(unique_contacts.keys())
                contact_id_map = {}
                for i in range(0, len(lookup_keys), BATCH_SIZE):
                    chunk = lookup_keys[i : i + BATCH_SIZE]
                    values_ph = ", ".join(["(%s, %s, %s)"] * len(chunk))
                    flat_params = [p for key in chunk for p in key]
                    results = (
                        SQLExecuteQueryOperator(
                            task_id=f"batch_lookup_contacts_{i}",
                            conn_id=db_conn_id,
                            sql=f"""
                            SELECT c.id, c.email, c.nom, c.prenom
                            FROM main.contact c
                            JOIN (VALUES {values_ph}) AS v(email, nom, prenom)
                              ON c.email = v.email AND c.nom = v.nom AND c.prenom = v.prenom
                            WHERE c.fonction = '{REFERENT_FONCTION}';
                        """,
                            parameters=flat_params,
                        ).execute(context=context)
                        or []
                    )
                    for cid, email, nom, prenom in results:
                        contact_id_map[(email, nom, prenom)] = cid

                # 5d: Batch insert contact_structure
                link_rows = []
                for email, nom, prenom, _, s_tp_id in contact_data:
                    contact_id = contact_id_map.get((email, nom, prenom))
                    if not contact_id:
                        continue
                    link_rows.append((s_tp_id, contact_id))

                for i in range(0, len(link_rows), BATCH_SIZE):
                    chunk = link_rows[i : i + BATCH_SIZE]
                    values_ph = ", ".join(["(%s, %s)"] * len(chunk))
                    flat_params = [p for r in chunk for p in r]
                    SQLExecuteQueryOperator(
                        task_id=f"batch_insert_contact_structure_{i}",
                        conn_id=db_conn_id,
                        sql=f"""
                            INSERT INTO main.contact_structure_administrative (structure_administrative_id, contact_id)
                            SELECT sa.id, v.contact_id
                            FROM (VALUES {values_ph}) AS v(structure_tp_id, contact_id)
                            JOIN main.structure_administrative sa ON sa.structure_tp_id = v.structure_tp_id
                            ON CONFLICT ON CONSTRAINT contact_structure_administrative_unique DO NOTHING;
                        """,
                        parameters=flat_params,
                    ).execute(context=context)

                logging.info(f"{len(contact_data)} contacts synchronisés.")

        except Exception as e:
            logging.error(f"Erreur lors de l'insertion des données : {e}")
            raise

    init_dir = BashOperator(
        task_id="init_working_dir",
        bash_command="""
                    set -e
                    rm -rf {{ params['working_dir'] }} && mkdir -p {{ params['working_dir'] }}
                """,
    )

    truncate_formation_table = SQLExecuteQueryOperator(
        task_id="truncate_formation_table",
        conn_id="{{ params['db_conn_id'] }}",
        sql="TRUNCATE TABLE main.formation RESTART IDENTITY;",
    )

    truncate_subvention_table = SQLExecuteQueryOperator(
        task_id="truncate_subvention_table",
        conn_id="{{ params['db_conn_id'] }}",
        sql="TRUNCATE TABLE main.subvention RESTART IDENTITY;",
    )

    truncate_contrat_table = SQLExecuteQueryOperator(
        task_id="truncate_contrat_table",
        conn_id="{{ params['db_conn_id'] }}",
        sql="TRUNCATE TABLE main.contrat RESTART IDENTITY;",
    )
    truncate_poste_table = SQLExecuteQueryOperator(
        task_id="truncate_poste_table",
        conn_id="{{ params['db_conn_id'] }}",
        sql="TRUNCATE TABLE main.poste RESTART IDENTITY CASCADE;",
    )
    get_conum_file = PythonOperator(
        task_id="download_file",
        python_callable=download_from_s3,
    )
    process_data_conum_task = PythonOperator(
        task_id="process_data_conum",
        python_callable=process_data_conum,
    )
    write_to_source_task = PythonOperator(
        task_id="write_to_source",
        python_callable=write_to_source,
    )

    valider_contrat_idposte_task = PythonOperator(
        task_id="valider_contrat_idposte",
        python_callable=valider_contrat_idposte,
    )

    enrich_structures_caches_task = PythonOperator(
        task_id="enrich_structures_caches",
        python_callable=enrich_structures_caches,
    )

    process_poste_file_task = PythonOperator(
        task_id="process_poste_file",
        python_callable=process_poste_file,
    )

    process_personne_upsert_file_task = PythonOperator(
        task_id="process_personne_upsert_file",
        python_callable=process_personne_upsert_file,
    )

    process_personne_affectations_file_task = PythonOperator(
        task_id="process_personne_affectations_file",
        python_callable=process_personne_affectations_file,
    )

    process_enriched_structure_task = PythonOperator(
        task_id="process_enriched_structure",
        python_callable=process_enriched_structure,
    )

    process_formation_file_task = PythonOperator(
        task_id="process_formation_file",
        python_callable=process_formation_file,
    )
    process_subvention_file_task = PythonOperator(
        task_id="process_subvention_file",
        python_callable=process_subvention_file,
    )
    process_contrat_file_task = PythonOperator(
        task_id="process_contrat_file",
        python_callable=process_contrat_file,
    )

    (
        init_dir
        >> get_conum_file
        >> process_data_conum_task
        >> enrich_structures_caches_task
        >> process_enriched_structure_task
        >> process_personne_upsert_file_task
        >> truncate_contrat_table
        >> process_contrat_file_task
        >> process_personne_affectations_file_task
        >> truncate_poste_table
        >> process_poste_file_task
        >> [truncate_formation_table, truncate_subvention_table]
    )

    truncate_formation_table >> process_formation_file_task
    truncate_subvention_table >> process_subvention_file_task

    # Capture brute (dead-end parallèle) : ne s'intercale pas dans le flux principal.
    get_conum_file >> write_to_source_task
    # Validation de contrat (mode warn) en dead-end après la capture.
    write_to_source_task >> valider_contrat_idposte_task
