import gc
import logging
from datetime import date
from datetime import datetime
from datetime import timedelta

import pandas as pd
import pendulum
from airflow import DAG
from airflow.models import Variable
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.python import ShortCircuitOperator
from airflow.providers.standard.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sdk import Param

from etl.core.ac import normaliser_code_postal
from etl.core.ac import transformer_aidants
from etl.core.ac import transformer_structures
from etl.core.coop import dedupe_par_id
from etl.extract.connectors.http_airflow import APIClientOperator
from etl.load.aidants_connect import build_sirene_update_row
from etl.load.aidants_connect import ingest_personne_affectations
from etl.load.aidants_connect import ingest_structures
from etl.load.aidants_connect import ingest_utilisateurs
from mattermost_notifier import MattermostNotifier

DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 3,
    "retry_delay": timedelta(minutes=2),
    "retry_exponential_backoff": True,
}

DAG_ID = "aidants-connect-import"
START_DATE = pendulum.datetime(2025, 5, 1, tz="Europe/Paris")

CONN_ID = "fne_aidants"

# Endpoints racine (la pagination est gérée par APIClientOperator)
AIDANTS_ENDPOINT = "/api/DfHGbvUGCHQD/fne_aidants/"
STRUCTURES_ENDPOINT = "/api/DfHGbvUGCHQD/fne_organisations/"


# === Notifier (lazy singleton) ===
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


# === Helpers enrichissement ===


def _normalize_cp(val):
    """Normalise un code postal AC à 5 chiffres.

    L'API AC renvoie le CP **sans zéro initial** (`1110` au lieu de `01110`, ou
    `1110.0` quand pandas l'a converti en float). Sans ce lpad, le filtre
    `postcode` de la BAN ne matche pas et le géocodeur retombe sur un homonyme.
    On ne zfill que les valeurs purement numériques (les CP corses `2A`/`2B`
    n'existent pas en CP, mais on reste défensif).
    """
    if pd.isna(val):
        return val
    return normaliser_code_postal(val)


def _should_enrich_structure_ac(ac_id, map_ac, cutoff_date):
    """Détermine si une structure doit être enrichie.

    Returns: (should_enrich, will_update_db)
    """
    if not ac_id or ac_id not in map_ac:
        return True, False

    rec = map_ac.get(ac_id, {})
    if not rec.get("siret"):
        return False, False

    last_dt = rec.get("last")
    if last_dt is None:
        return True, True

    try:
        if isinstance(last_dt, datetime):
            last_p = pendulum.instance(last_dt, tz="Europe/Paris")
        elif isinstance(last_dt, date):
            last_p = pendulum.datetime(
                last_dt.year, last_dt.month, last_dt.day, tz="Europe/Paris"
            )
        else:
            last_p = pendulum.parse(str(last_dt))
            if last_p.tzinfo is None:
                last_p = last_p.replace(tzinfo=pendulum.timezone("Europe/Paris"))
        should = last_p.date() <= cutoff_date
    except Exception:
        should = True

    return should, should


def _enrich_chunk_sirene_ban(
    df_chunk, api_key_insee, sirene_instance, geocodeur_instance
):
    """Enrichit un DataFrame chunk avec SIRENE + BAN batch.

    Retourne le DataFrame enrichi (colonnes ajoutées/modifiées in place).
    """
    sirene_cols = [
        "etat_administratif",
        "code_activite_principale",
        "categorie_juridique",
        "denomination_sirene",
        "adresse_sirene",
        "code_insee_sirene",
    ]

    # --- SIRENE ---
    if "siret" in df_chunk.columns:
        df_avec_siret = df_chunk[
            df_chunk["siret"].notna() & (df_chunk["siret"].str.strip() != "")
        ]
    else:
        df_avec_siret = pd.DataFrame()

    if len(df_avec_siret) > 0 and api_key_insee and sirene_instance:
        try:
            df_sirene = sirene_instance.enrichir_dataframe(
                df_chunk,
                colonne_id="_row_idx",
                colonne_siret="siret",
            )
            df_chunk = df_chunk.merge(
                df_sirene[["id_source"] + sirene_cols],
                left_on="_row_idx",
                right_on="id_source",
                how="left",
                suffixes=("", "_sirene_new"),
            )
            if "id_source" in df_chunk.columns:
                df_chunk.drop(columns=["id_source"], inplace=True)
            for col in sirene_cols:
                new_col = f"{col}_sirene_new"
                if new_col in df_chunk.columns:
                    df_chunk[col] = df_chunk[new_col].combine_first(df_chunk.get(col))
                    df_chunk.drop(columns=[new_col], inplace=True)
            logging.info(f"SIRENE batch : {len(df_avec_siret)} SIRET traités.")
        except Exception as e:
            logging.error(f"Erreur enrichissement SIRENE batch : {e}")
            for col in sirene_cols:
                if col not in df_chunk.columns:
                    df_chunk[col] = None
    else:
        for col in sirene_cols:
            if col not in df_chunk.columns:
                df_chunk[col] = None

    # --- BAN ---
    if "adresse" in df_chunk.columns:
        df_chunk["adresse_recherche"] = df_chunk["adresse"].apply(
            lambda x: str(x).strip() if pd.notna(x) else ""
        )
        df_avec_adresse = df_chunk[df_chunk["adresse_recherche"].str.strip() != ""]
    else:
        df_chunk["adresse_recherche"] = ""
        df_avec_adresse = pd.DataFrame()

    # Filtre BAN par code_postal (postcode), PAS par code_insee (citycode) : le
    # `code_insee` d'AC vient brut de l'API (`city_insee_code`) et est pollué
    # (placeholder 57490/Moyenvic, désync avec city/zipcode). Le CP, lui, est
    # fiable — à condition de le normaliser à 5 chiffres : AC l'envoie sans zéro
    # initial (`1110` → `01110`), sinon le filtre postcode ne matche pas.
    # Cf docs/fix-ingestion-ac-geocodage-cp.md (A/B : conformité SIRENE 34→69 %).
    if "code_postal" in df_chunk.columns:
        df_chunk["code_postal"] = df_chunk["code_postal"].apply(_normalize_cp)

    if len(df_avec_adresse) > 0 and geocodeur_instance:
        try:
            df_geocode = geocodeur_instance.geocoder_dataframe(
                df_chunk,
                colonne_id="_row_idx",
                colonne_adresse="adresse_recherche",
                colonne_code_postal="code_postal"
                if "code_postal" in df_chunk.columns
                else None,
            )
            geo_merge_cols = [
                "id_source",
                "numero_voie",
                "nom_voie",
                "nom_commune",
                "code_postal_geocode",
                "code_insee_geocode",
                "longitude",
                "latitude",
                "geom",
                "clef_interop",
                "code_ban",
            ]
            available_cols = [c for c in geo_merge_cols if c in df_geocode.columns]
            # Suffixes explicites : sans ça, pandas crée nom_commune_x / nom_commune_y
            # silencieusement, ce qui casse le fallback INSERT main.adresse en aval.
            df_chunk = df_chunk.merge(
                df_geocode[available_cols],
                left_on="_row_idx",
                right_on="id_source",
                how="left",
                suffixes=("", "_ban"),
            )
            if "id_source" in df_chunk.columns:
                df_chunk.drop(columns=["id_source"], inplace=True)

            # Consolider nom_commune : priorité BAN (orthographe normalisée), fallback source.
            # Quand BAN n'a trouvé aucun résultat, nom_commune_ban est NULL et on
            # conserve la valeur source.
            if "nom_commune_ban" in df_chunk.columns:
                df_chunk["nom_commune"] = df_chunk["nom_commune_ban"].combine_first(
                    df_chunk.get("nom_commune")
                )
                df_chunk.drop(columns=["nom_commune_ban"], inplace=True)

            # Consolider code_postal : priorité BAN (postcode normalisé du résultat),
            # fallback CP source (déjà zfillé). Fait avant le calcul du département.
            if "code_postal_geocode" in df_chunk.columns:
                df_chunk["code_postal"] = df_chunk["code_postal_geocode"].combine_first(
                    df_chunk.get("code_postal")
                )
                df_chunk.drop(columns=["code_postal_geocode"], inplace=True)

            # Département : on s'appuie sur le résultat BAN (code_insee_geocode,
            # canonique — gère la Corse 2A/2B), à défaut sur le CP consolidé. On
            # n'utilise PLUS le code_insee source, pollué.
            df_chunk["departement"] = df_chunk.apply(
                lambda row: (
                    str(row.get("code_insee_geocode") or "")[:2]
                    if pd.notna(row.get("code_insee_geocode"))
                    and str(row.get("code_insee_geocode")).strip()
                    else str(row.get("code_postal") or "")[:2]
                    if pd.notna(row.get("code_postal"))
                    and str(row.get("code_postal")).strip()
                    else None
                ),
                axis=1,
            )

            # Consolider code_insee : priorité BAN (citycode canonique), fallback
            # source. Quand BAN n'a rien matché, code_insee_geocode est NULL et on
            # retombe sur la valeur source (potentiellement polluée, mais aucune
            # meilleure alternative à ce stade).
            if "code_insee_geocode" in df_chunk.columns:
                df_chunk["code_insee"] = df_chunk["code_insee_geocode"].combine_first(
                    df_chunk.get("code_insee")
                )
                df_chunk.drop(columns=["code_insee_geocode"], inplace=True)
            df_chunk["repetition"] = None
            logging.info(f"BAN batch : {len(df_avec_adresse)} adresses traitées.")
        except Exception as e:
            logging.error(f"Erreur enrichissement BAN batch : {e}")

    # Nettoyer colonnes temporaires
    for col in ["_row_idx", "adresse_recherche", "longitude", "latitude"]:
        if col in df_chunk.columns:
            df_chunk.drop(columns=[col], inplace=True)

    return df_chunk


# === Couche silver (schéma staging) — fiche 01 approche-data ===
#
# États transformés du run matérialisés dans staging.ac__* (V129), reconstruits
# à chaque run (TRUNCATE + INSERT) et 100 % re-dérivables depuis la capture
# brute source.ac__* (bronze) + les cores purs etl/core/ac.py. Les lecteurs
# (enrich, ingest_*) lisent staging — plus de XCom de données.

AC_STRUCTURES_IMPORT_COLS = [
    "structure_ac_id",
    "updated_at_ac",
    "is_active_ac",
    "nom",
    "siret",
    "nom_commune",
    "code_postal",
    "code_insee",
    "adresse",
    "nb_mandats_ac",
    "dispositif_programmes_nationaux",
]

AC_AIDANTS_IMPORT_COLS = [
    "aidant_connect_id",
    "updated_at_ac",
    "prenom",
    "nom",
    "is_active_ac",
    "formation_fne_ac",
    "profession_ac",
    "nb_accompagnements_ac",
    "is_referent_ac",
    "structure_ac_id",
]


def _lire_source_run(conn, table, run_id):
    """Objets bruts capturés dans `table` pour ce dag_run, dédupliqués par id.

    Un retry du fetch peut capturer deux fois la même page dans source.*
    (append-only) : on ne garde que la version la plus récente de chaque objet.
    """
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT donnee FROM {table} WHERE run_id = %s ORDER BY id",
            (run_id,),
        )
        return dedupe_par_id([r[0] for r in cur.fetchall()])


def _replace_staging_rows(conn, table, cols, rows, run_id):
    """TRUNCATE puis INSERT des lignes (liste de dicts) dans staging.<table>.

    Silver reconstruit à chaque run : la table ne porte que le dernier run,
    l'historique reste dans source.* (bronze).
    """
    from psycopg2.extras import execute_values

    values = [[run_id] + [r.get(c) for c in cols] for r in rows]
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE staging.{table}")
        if values:
            execute_values(
                cur,
                f"INSERT INTO staging.{table} (run_id, {', '.join(cols)}) VALUES %s",
                values,
            )
    conn.commit()
    logging.info("Silver staging.%s : %d lignes (run %s).", table, len(values), run_id)


def _read_staging_rows(conn, table, cols):
    """Lit staging.<table> en liste de dicts (mêmes clés que l'ancien XCom)."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT {', '.join(cols)} FROM staging.{table}")
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def stage_aidants(**kwargs):
    """Silver : relit la capture brute source.ac__aidants du run (la base est
    l'interface, fiche 15), applique le core pur et matérialise le DELTA
    transformé dans staging.ac__aidants.

    Le fetch est un stock complet (fusion 2026-07-31) mais le silver est
    re-filtré sur updated_at_ac >= MAX(main.personne.updated_at_ac) — même
    critère que l'ancien fetch incrémental ?updated_at__gte=. Comportement
    iso pré-fusion pour tout l'aval (ingest_users, affectations, gate lazy) :
    sans ce filtre, le gate lazy voit les 18 500 aidants du stock et réveille
    des structures dormantes → UniqueViolation sur
    structure_administrative_siret_antenne_ukey (bug ON CONFLICT documenté
    dans etl/load/aidants_connect.py, non corrigé)."""
    db_conn_id = kwargs["params"]["db_conn_id"]
    run_id = kwargs["run_id"]
    conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
    try:
        items = _lire_source_run(conn, "source.ac__aidants", run_id)
        rows = transformer_aidants(items)
        with conn.cursor() as cur:
            cur.execute("SELECT MAX(updated_at_ac) FROM main.personne")
            max_ts = cur.fetchone()[0]
        if max_ts is not None:
            seuil = max_ts.strftime("%Y-%m-%d %H:%M:%S.%f")
            total = len(rows)
            rows = [
                r for r in rows if r["updated_at_ac"] and r["updated_at_ac"] >= seuil
            ]
            logging.info(
                "Delta silver : %d aidants modifiés depuis %s (sur %d au stock).",
                len(rows),
                seuil,
                total,
            )
        _replace_staging_rows(conn, "ac__aidants", AC_AIDANTS_IMPORT_COLS, rows, run_id)
    finally:
        conn.close()


def stage_structures(**kwargs):
    """Silver : relit la capture brute source.ac__structures du run, applique
    le core pur et matérialise le stock transformé dans staging.ac__structures."""
    db_conn_id = kwargs["params"]["db_conn_id"]
    run_id = kwargs["run_id"]
    conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
    try:
        items = _lire_source_run(conn, "source.ac__structures", run_id)
        rows = transformer_structures(items)
        _replace_staging_rows(
            conn, "ac__structures", AC_STRUCTURES_IMPORT_COLS, rows, run_id
        )
    finally:
        conn.close()


AC_ACCOMPAGNEMENTS_COLS = ["aidant_connect_id", "mois", "nb_accompagnements"]


def stage_accompagnements(**kwargs):
    """Silver : déplie la fenêtre glissante get_supports_number_last_six_months
    de la capture brute source.ac__aidants du run (stock complet) dans
    staging.ac__accompagnements, via le core pur.

    L'index 0 du payload correspond au mois du fetch (calculé à l'exécution,
    pas à la date logique Airflow). Le mois courant est partiel : il est
    consolidé au fil des runs quotidiens par l'upsert de load_accompagnements
    (les mois recouvrants sont écrasés par la valeur la plus fraîche).
    """
    from etl.core.ac import transformer_accompagnements
    from etl.quarantaine import make_rejets_sink

    db_conn_id = kwargs["params"]["db_conn_id"]
    run_id = kwargs["run_id"]
    conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
    try:
        items = _lire_source_run(conn, "source.ac__aidants", run_id)
        mois_courant = pendulum.now("Europe/Paris").start_of("month").date()
        rows, rejets = transformer_accompagnements(items, mois_courant)
        _replace_staging_rows(
            conn, "ac__accompagnements", AC_ACCOMPAGNEMENTS_COLS, rows, run_id
        )
        # Quarantaine (fiche 03) : items sans id → staging.rejets. Après le
        # commit du silver (le sink best-effort rollback en cas d'erreur).
        if rejets:
            make_rejets_sink(
                conn, run_id, flux="ac__aidants", etape="stage_accompagnements"
            )(rejets)
    finally:
        conn.close()


def load_accompagnements(**kwargs):
    """Upsert (aidant_connect_id, mois) → nb_accompagnements depuis le
    silver staging.ac__accompagnements (déjà typé et dédupliqué sur la
    clef unique par le core)."""
    from psycopg2.extras import execute_values

    db_conn_id = kwargs["params"]["db_conn_id"]

    conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT aidant_connect_id, mois, nb_accompagnements "
                "FROM staging.ac__accompagnements"
            )
            rows = cursor.fetchall()

        if not rows:
            logging.warning("staging.ac__accompagnements vide, rien à charger.")
            return

        with conn.cursor() as cursor:
            execute_values(
                cursor,
                """
                INSERT INTO main.ac_accompagnements_mensuels
                    (aidant_connect_id, mois, nb_accompagnements)
                VALUES %s
                ON CONFLICT (aidant_connect_id, mois) DO UPDATE SET
                    nb_accompagnements = EXCLUDED.nb_accompagnements,
                    fetched_at = now()
                """,
                rows,
            )
        conn.commit()
        logging.info(
            "%d lignes (aidant, mois) upsertées dans main.ac_accompagnements_mensuels.",
            len(rows),
        )
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# === Fonctions principales du DAG ===


def _structure_merite_creation(rec, aidant_struct_ids):
    """Une structure AC *nouvelle* (absente de SA) mérite-t-elle d'être créée ?

    True si elle a déjà servi (nb_mandats >= 1) ou si un aidant du run la
    référence (une affectation sera créée). Sinon c'est une coquille vide
    (cf gate lazy dans enrich_structures_batch).
    """
    ac_id = rec.get("structure_ac_id")
    if ac_id and ac_id in aidant_struct_ids:
        return True
    raw = rec.get("nb_mandats_ac")
    try:
        return raw is not None and int(float(str(raw))) >= 1
    except (TypeError, ValueError):
        return False


def enrich_structures_batch(**kwargs):
    """Enrichit les structures en batch via les caches SIRENE + géocodage.

    Lit le silver staging.ac__structures (et staging.ac__aidants pour le gate
    lazy), remplit les caches d'enrichissement (cache-first, V137) et met à
    jour les structures existantes en base. Plus de CSV ni de XCom (lot 2
    caches) : structures_ingest re-dérive la sélection des nouvelles et
    rejoint le silver aux caches.
    """
    db_conn_id = (kwargs.get("params") or {}).get("db_conn_id", "sonum-test-db")

    # Connexion unique du run : lectures silver + capture brute BAN (le sink
    # de la couche source commit à chaque batch).
    source_conn = PostgresHook(postgres_conn_id=db_conn_id).get_conn()

    all_structures = _read_staging_rows(
        source_conn, "ac__structures", AC_STRUCTURES_IMPORT_COLS
    )
    if not all_structures:
        logging.warning("Aucune structure à enrichir (staging.ac__structures vide).")
        source_conn.close()
        return None

    logging.info(
        f"{len(all_structures)} structures lues depuis staging.ac__structures."
    )

    # --- Gate "création lazy" (cf #1468 / refonte phase 4a) ---
    # L'API AC liste ~8 300 structures, dont ~2 050 sont des coquilles vides
    # (0 mandat, aucun aidant rattaché) — précisément les orphelines supprimées
    # en phase 0.5 que la source ré-émet à chaque run. On ne (re)crée une SA AC
    # que si la structure est *utile* : soit elle a déjà servi (nb_mandats >= 1),
    # soit elle est référencée par un aidant du run courant (donc une affectation
    # va être créée). Les structures déjà présentes en SA ne sont pas concernées
    # par ce gate (elles continuent d'être enrichies / mises à jour).
    with source_conn.cursor() as cur:
        cur.execute(
            "SELECT DISTINCT structure_ac_id FROM staging.ac__aidants "
            "WHERE structure_ac_id IS NOT NULL"
        )
        aidant_struct_ids = {r[0] for r in cur.fetchall()}
    logging.info(
        "Gate lazy : %s structures référencées par un aidant du run.",
        len(aidant_struct_ids),
    )

    # --- 1) Batch query : récupérer last_sirene_enrich_at ---
    all_ac_ids = [
        r.get("structure_ac_id") for r in all_structures if r.get("structure_ac_id")
    ]

    map_ac = {}
    BATCH_SIZE = 500
    try:
        for i in range(0, len(all_ac_ids), BATCH_SIZE):
            batch = all_ac_ids[i : i + BATCH_SIZE]
            placeholders = ", ".join(["%s"] * len(batch))
            res = (
                SQLExecuteQueryOperator(
                    task_id=f"get_last_sirene_enrich_{i // BATCH_SIZE}",
                    conn_id=db_conn_id,
                    sql=f"""
                    SELECT structure_ac_id, siret, last_sirene_enrich_at
                    FROM main.structure_administrative
                    WHERE structure_ac_id IN ({placeholders})
                """,
                    parameters=batch,
                ).execute(context=kwargs)
                or []
            )
            for sid, siret, ts in res:
                map_ac[sid] = {"siret": siret, "last": ts}
    except Exception as e:
        if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
            logging.warning(
                "Table main.structure_administrative absente, toutes les structures seront enrichies."
            )
        else:
            raise

    logging.info(f"{len(all_ac_ids)} ac_ids uniques, {len(map_ac)} trouvés en base.")

    # --- 2) Préparer les instances d'enrichissement ---
    cutoff_date = pendulum.now("UTC").subtract(months=4).date()
    existing_ac_ids = set(map_ac.keys())

    api_key_insee = Variable.get("API_SIRENE_TOKEN", default_var=None)
    if not api_key_insee:
        logging.warning(
            "Variable Airflow 'API_SIRENE_TOKEN' absente, enrichissement SIRENE ignoré."
        )

    from etl.enrichment_cache import GeocodeurAvecCache
    from etl.enrichment_cache import SireneAvecCache
    from etl.geocoding_batch import GeocodeurBatch
    from etl.quarantaine import make_rejets_sink
    from etl.sirene_batch import SireneBatch
    from etl.source_capture import BAN_TABLE
    from etl.source_capture import SIRENE_TABLE
    from etl.source_capture import make_source_sink

    # Capture brute des retours API (couche source) + cache d'enrichissement
    # (staging.*__cache, V137) : cache-first, seuls les manquants/périmés
    # partent à l'API. Réutilise la connexion du run.
    sirene_instance = (
        SireneAvecCache(
            source_conn,
            kwargs["run_id"],
            SireneBatch(
                api_key=api_key_insee,
                source_sink=make_source_sink(
                    source_conn, kwargs["run_id"], SIRENE_TABLE
                ),
            ),
        )
        if api_key_insee
        else None
    )
    geocodeur_instance = GeocodeurAvecCache(
        source_conn,
        kwargs["run_id"],
        GeocodeurBatch(
            source_sink=make_source_sink(source_conn, kwargs["run_id"], BAN_TABLE)
        ),
        rejets_sink=make_rejets_sink(
            source_conn,
            kwargs["run_id"],
            flux="ac__structures",
            etape="enrichissement",
        ),
    )

    # --- 3) Traitement par chunks ---
    read_chunksize = 500
    total_enriched = 0
    total_skipped = 0
    total_skipped_lazy = 0
    update_rows = []
    now_ts = pendulum.now("UTC")

    for chunk_start in range(0, len(all_structures), read_chunksize):
        chunk_records = all_structures[chunk_start : chunk_start + read_chunksize]

        to_enrich_rows = []
        to_enrich_will_update = []

        for r in chunk_records:
            ac_id = r.get("structure_ac_id")

            # Gate lazy : une structure nouvelle (absente de SA) qui n'a ni
            # mandat ni aidant rattaché est une coquille vide → on ne l'enrichit
            # pas et on ne la crée pas. Les structures déjà en SA passent (update).
            if ac_id not in existing_ac_ids and not _structure_merite_creation(
                r, aidant_struct_ids
            ):
                total_skipped_lazy += 1
                continue

            should_enrich, will_update = _should_enrich_structure_ac(
                ac_id, map_ac, cutoff_date
            )

            if should_enrich:
                to_enrich_rows.append(r)
                to_enrich_will_update.append(will_update)
            else:
                total_skipped += 1

        if not to_enrich_rows:
            continue

        # Enrichir ce chunk
        df_enrich = pd.DataFrame(to_enrich_rows)
        df_enrich["_row_idx"] = [str(i) for i in range(len(to_enrich_rows))]

        df_enrich = _enrich_chunk_sirene_ban(
            df_enrich,
            api_key_insee,
            sirene_instance,
            geocodeur_instance,
        )

        enriched_records = df_enrich.to_dict(orient="records")
        total_enriched += len(enriched_records)

        # Collecter les updates DB des structures existantes
        for rec, will_update in zip(enriched_records, to_enrich_will_update):
            if will_update:
                row = build_sirene_update_row(rec, now_ts)
                if row is not None:
                    update_rows.append(row)

        logging.info(
            f"Chunk traité : {len(enriched_records)} enrichies "
            f"(total enrichies: {total_enriched}, skippées: {total_skipped})"
        )
        del df_enrich, enriched_records, to_enrich_rows
        gc.collect()

    # --- 4) Batch UPDATE des structures existantes en base ---
    if update_rows:
        logging.info(f"Batch UPDATE de {len(update_rows)} structures existantes.")
        for i in range(0, len(update_rows), BATCH_SIZE):
            chunk = update_rows[i : i + BATCH_SIZE]
            values_ph = ", ".join(["(%s, %s, %s, %s, %s, %s)"] * len(chunk))
            flat_params = [p for r in chunk for p in r]
            SQLExecuteQueryOperator(
                task_id=f"batch_update_structures_{i // BATCH_SIZE}",
                conn_id=db_conn_id,
                sql=f"""
                    UPDATE main.structure_administrative AS s SET
                        etat_administratif = COALESCE(v.etat, s.etat_administratif),
                        code_activite_principale = COALESCE(v.ape, s.code_activite_principale),
                        categorie_juridique = COALESCE(v.cj, s.categorie_juridique),
                        denomination_sirene = COALESCE(v.denom, s.denomination_sirene),
                        last_sirene_enrich_at = v.ts
                    FROM (VALUES {values_ph})
                        AS v(etat, ape, cj, denom, ts, ac_id)
                    WHERE s.structure_ac_id = v.ac_id::uuid
                """,
                parameters=flat_params,
            ).execute(context=kwargs)

    source_conn.close()

    logging.info(
        f"Enrichissement terminé : {total_enriched} enrichies, "
        f"{total_skipped} skippées (SIRENE à jour), "
        f"{total_skipped_lazy} skippées (gate lazy : coquilles vides)."
    )


def utilisateurs_ingest(**kwargs):
    """Wrapper Airflow → ingest_utilisateurs. Lit le silver staging.ac__aidants."""
    db_conn_id = kwargs["params"]["db_conn_id"]

    hook = PostgresHook(postgres_conn_id=db_conn_id)
    conn = hook.get_conn()
    try:
        aidants = _read_staging_rows(conn, "ac__aidants", AC_AIDANTS_IMPORT_COLS)
        logging.info(f"{len(aidants)} utilisateurs à ingérer (batch mode).")
        result = ingest_utilisateurs(conn, aidants)
        conn.commit()
        logging.info("Batch utilisateurs_ingest terminé. %s", result)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def structures_ingest_dag(**kwargs):
    """Wrapper Airflow → ingest_structures.

    Lot 2 caches : plus de CSV ni de XCom. Relit le silver
    staging.ac__structures, re-dérive la sélection des nouvelles structures
    (absentes de SA + gate lazy, mêmes règles que enrich_structures_batch —
    l'enrich ne fait qu'UPDATE, l'ensemble des SA existantes est inchangé
    entre les deux tâches) et joint les caches d'enrichissement V137
    (etl/core/ac.py:consolider_structures_ac).
    """
    from etl.core.ac import cle_geocodage_structure_ac
    from etl.core.ac import consolider_structures_ac
    from etl.core.enrichissement import normaliser_siret
    from etl.core.enrichissement import siret_valide
    from etl.enrichment_cache import lire_cache_geocodage
    from etl.enrichment_cache import lire_cache_sirene

    db_conn_id = kwargs["params"]["db_conn_id"]

    hook = PostgresHook(postgres_conn_id=db_conn_id)
    conn = hook.get_conn()
    try:
        structures = _read_staging_rows(
            conn, "ac__structures", AC_STRUCTURES_IMPORT_COLS
        )
        if not structures:
            logging.warning("Aucune structure (staging.ac__structures vide).")
            return

        with conn.cursor() as cur:
            cur.execute(
                "SELECT DISTINCT structure_ac_id FROM staging.ac__aidants "
                "WHERE structure_ac_id IS NOT NULL"
            )
            aidant_struct_ids = {r[0] for r in cur.fetchall()}

        # SA existantes : mêmes ac_ids que le lookup de enrich_structures_batch.
        ac_ids = [s["structure_ac_id"] for s in structures if s.get("structure_ac_id")]
        existing_ac_ids = set()
        try:
            with conn.cursor() as cur:
                for i in range(0, len(ac_ids), 500):
                    batch = ac_ids[i : i + 500]
                    placeholders = ", ".join(["%s"] * len(batch))
                    cur.execute(
                        "SELECT structure_ac_id FROM main.structure_administrative "
                        f"WHERE structure_ac_id IN ({placeholders})",
                        batch,
                    )
                    existing_ac_ids.update(r[0] for r in cur.fetchall())
        except Exception as e:
            if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
                conn.rollback()
                logging.warning(
                    "Table main.structure_administrative absente, toutes les "
                    "structures seront considérées nouvelles."
                )
            else:
                raise

        nouvelles = [
            s
            for s in structures
            if s.get("structure_ac_id")
            and s["structure_ac_id"] not in existing_ac_ids
            and _structure_merite_creation(s, aidant_struct_ids)
        ]
        logging.info(
            "%s nouvelles structures (sur %s au silver, %s déjà en SA).",
            len(nouvelles),
            len(structures),
            len(existing_ac_ids),
        )

        sirets = [
            s
            for s in (normaliser_siret(n.get("siret")) for n in nouvelles)
            if siret_valide(s)
        ]
        cles_geo = [c for c in (cle_geocodage_structure_ac(n) for n in nouvelles) if c]
        hits_sirene = lire_cache_sirene(conn, sirets)
        hits_geo = lire_cache_geocodage(conn, cles_geo)

        rows = consolider_structures_ac(nouvelles, hits_sirene, hits_geo)
        result = ingest_structures(conn, rows)
        conn.commit()

        # Quarantaine après commit : le sink commit lui-même (etl/quarantaine.py),
        # l'appeler avant casserait l'atomicité de l'ingestion.
        rejets = result.pop("rejets", [])
        if rejets:
            from etl.quarantaine import make_rejets_sink

            make_rejets_sink(
                conn, kwargs["run_id"], flux="ac__structures", etape="ingest"
            )(rejets)

        logging.info("Batch structures_ingest terminé. %s", result)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def personne_affectations_ingest_dag(**kwargs):
    """Wrapper Airflow → ingest_personne_affectations. Lit staging.ac__aidants."""
    db_conn_id = kwargs["params"]["db_conn_id"]

    hook = PostgresHook(postgres_conn_id=db_conn_id)
    conn = hook.get_conn()
    try:
        aidants = _read_staging_rows(conn, "ac__aidants", AC_AIDANTS_IMPORT_COLS)
        logging.info(f"{len(aidants)} affectations à traiter (batch mode).")
        result = ingest_personne_affectations(conn, aidants)
        conn.commit()
        logging.info("Batch personne_affectations terminé. %s", result)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def valider_contrat_aidants(**kwargs):
    """Validation de contrat mode warn (fiche 02) : relit la capture brute
    du run dans source.ac__aidants et la confronte à contracts/ac__aidants.yml.
    Dead-end, jamais bloquant."""
    # Import lazy pour ne pas alourdir le parsing du DAG
    from etl.contrat_validation import valider_contrat_source

    valider_contrat_source(
        table="source.ac__aidants",
        contrat_nom="ac__aidants",
        db_conn_id=kwargs["params"]["db_conn_id"],
        run_id=kwargs["run_id"],
    )


def valider_contrat_structures(**kwargs):
    """Validation de contrat mode warn (fiche 02) : relit la capture brute
    du run dans source.ac__structures et la confronte à
    contracts/ac__structures.yml. Dead-end, jamais bloquant."""
    # Import lazy pour ne pas alourdir le parsing du DAG
    from etl.contrat_validation import valider_contrat_source

    valider_contrat_source(
        table="source.ac__structures",
        contrat_nom="ac__structures",
        db_conn_id=kwargs["params"]["db_conn_id"],
        run_id=kwargs["run_id"],
    )


# === DAG Definition ===

with DAG(
    dag_id=DAG_ID,
    description="ETL Aidants-Connect : Recuperation des structures et des aidants depuis l'API Aidants-Connect, "
    "enrichissement des structures avec SIRET et géocodage.",
    default_args=DEFAULT_ARGS,
    start_date=START_DATE,
    dagrun_timeout=timedelta(minutes=120),
    on_failure_callback=dag_failure_callback,
    on_success_callback=dag_success_callback,
    schedule=None,
    params={
        "db_conn_id": Param(
            default="sonum-prod-db",
            type="string",
            enum=[
                "sonum-test-db",
                "sonum-dev-db",
                "sonum-prod-db",
            ],
            examples=[
                "sonum-test-db",
                "sonum-dev-db",
                "sonum-prod-db",
            ],
            title="Airflow DB connection id",
            description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
        ),
    },
    catchup=False,
    tags=["aidants-connect", "etl", "fne", "api"],
) as dag:
    token = Variable.get("aidants_connect_api_token")
    headers = {"Authorization": f"Token {token}"}

    # 1) Fetch structures : collecte + capture brute uniquement (couche
    # source) — la transformation est portée par stage_structures (core)
    # depuis source.ac__structures.
    fetch_all_aidants_structures = APIClientOperator(
        task_id="fetch_all_aidants_structures",
        conn_id=CONN_ID,
        headers=headers,
        endpoint=STRUCTURES_ENDPOINT,
        data_type="aidants-structures",
        source_table="source.ac__structures",
        source_db_conn_id="{{ params['db_conn_id'] }}",
    )

    enrich_structures_batch_task = PythonOperator(
        task_id="enrich_structures_batch",
        python_callable=enrich_structures_batch,
    )

    # Silver : source.ac__* du run → cores purs → staging.ac__* (chemin porteur).
    stage_structures_task = PythonOperator(
        task_id="stage_structures",
        python_callable=stage_structures,
    )

    stage_aidants_task = PythonOperator(
        task_id="stage_aidants",
        python_callable=stage_aidants,
    )

    # Accompagnements mensuels (ex-DAG aidants-connect-accompagnements,
    # fusionné) : dépliage de la fenêtre glissante depuis la même capture
    # brute, consolidation quotidienne de la série temporelle.
    stage_accompagnements_task = PythonOperator(
        task_id="stage_accompagnements",
        python_callable=stage_accompagnements,
    )

    load_accompagnements_task = PythonOperator(
        task_id="load_accompagnements",
        python_callable=load_accompagnements,
    )

    # 2) Fetch aidants : collecte + capture brute uniquement — la
    # transformation est portée par stage_aidants (core) depuis
    # source.ac__aidants. Fetch COMPLET (endpoint nu, ~18 500 aidants) : la
    # table source capture le stock du run — capture mutualisée
    # aidants + accompagnements (rétention : voir approche-data/19).
    fetch_all_aidants_personnes = APIClientOperator(
        task_id="fetch_all_aidants_personnes",
        conn_id=CONN_ID,
        headers=headers,
        endpoint=AIDANTS_ENDPOINT,
        data_type="aidants-personnes",
        source_table="source.ac__aidants",
        source_db_conn_id="{{ params['db_conn_id'] }}",
    )

    valider_contrat_aidants_task = PythonOperator(
        task_id="valider_contrat_aidants",
        python_callable=valider_contrat_aidants,
    )

    valider_contrat_structures_task = PythonOperator(
        task_id="valider_contrat_structures",
        python_callable=valider_contrat_structures,
    )

    # 3) Ingest tasks
    ingest_structures_task = PythonOperator(
        task_id="ingest_structures",
        python_callable=structures_ingest_dag,
    )

    ingest_users_task = PythonOperator(
        task_id="ingest_users",
        python_callable=utilisateurs_ingest,
    )

    personne_affectations_ingest_task = PythonOperator(
        task_id="ingest_personne_affectations",
        python_callable=personne_affectations_ingest_dag,
    )

    # 4) Triggers
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

    # --- Topologie ---
    # Chemin porteur : bronze (fetch + capture source) → silver (stage_*) →
    # enrichissement → gold (ingest_*).
    (
        fetch_all_aidants_structures
        >> stage_structures_task
        >> enrich_structures_batch_task
        >> ingest_structures_task
    )

    # Le gate "création lazy" de enrich_structures_batch lit staging.ac__aidants
    # (structures référencées par les aidants du run) → stage_aidants avant.
    stage_aidants_task >> enrich_structures_batch_task

    # Validation de contrat (mode warn) en branche dead-end : relit la
    # capture brute du run, ne bloque jamais l'aval.
    fetch_all_aidants_personnes >> valider_contrat_aidants_task
    fetch_all_aidants_structures >> valider_contrat_structures_task

    fetch_all_aidants_personnes >> stage_aidants_task >> ingest_users_task

    # Accompagnements : branche indépendante depuis la même capture brute.
    (
        fetch_all_aidants_personnes
        >> stage_accompagnements_task
        >> load_accompagnements_task
    )

    (
        ingest_structures_task
        >> ingest_users_task
        >> personne_affectations_ingest_task
        >> check_prod_for_carto_cache_reset
        >> trigger_carto_cache_reset
    )
