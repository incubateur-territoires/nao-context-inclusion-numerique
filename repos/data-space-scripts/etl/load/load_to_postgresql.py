import gzip
import json
import logging
import urllib.request

import pandas as pd
from airflow.providers.postgres.hooks.postgres import PostgresHook
from psycopg2.extras import execute_values

from etl.core.carto import controler_volumetrie
from etl.core.carto import transformer_lieux
from etl.database_utils import DTYPE_CARTO


# Endpoint public de la cartographie nationale (fichier déjà dédupliqué par
# mednum-cli nightly), consommé par dataspace à la place de réexécuter mednum-cli.
# URL stable data.gouv (redirige vers le dernier export nightly) — préférée à
# l'ancien endpoint CloudFront opaque. Servie en JSON non gzippé : le loader
# retombe sur le contenu brut (cf. try/except gzip). Contenu identique au
# CloudFront (mêmes 17 555 lieux) ; en plus, data.gouv porte structure_coop_id
# pré-rempli (champ que le loader recalcule lui-même, cf. load_carto_national_file).
NATIONAL_CARTO_URL = (
    "https://www.data.gouv.fr/api/1/datasets/r/b5e5a1e1-122e-4f87-b6cf-d1ce342671be"
)


def load_carto_national_file(
    conn_id: str,
    run_id: str,
    url: str = NATIONAL_CARTO_URL,
    source_sink=None,
    rejets_sink=None,
    seuil_volumetrique: float = 0.8,
) -> int:
    """
    Charge le fichier national déjà dédupliqué de la cartographie nationale
    dans le silver staging.carto__structures (TRUNCATE + INSERT, relu filtré
    sur run_id par integration_adresses / integration_lieux), à la place de
    réexécuter mednum-cli (transform / merge / split / dédup). Le fichier est
    la sortie `dedupliquer.merged-json` de mednum-cli, exposée publiquement
    et consommée par dataspace.

    - Télécharge le JSON (servi en gzip) depuis l'endpoint public.
    - Dérive structure_coop_id depuis l'id (préfixe 'Coop-numérique_<uuid>',
      y compris ids composés 'A__B').
    - Ne matérialise que les colonnes de staging.carto__structures
      (DTYPE_CARTO) ; le reste du JSON est ignoré.
    """
    logging.info("Téléchargement du fichier national carto : %s", url)
    with urllib.request.urlopen(url, timeout=120) as resp:
        raw = resp.read()

    # L'endpoint sert du gzip ; tolère un contenu déjà décompressé.
    try:
        data = gzip.decompress(raw)
    except (OSError, gzip.BadGzipFile):
        data = raw

    lieux = json.loads(data)
    logging.info("Fichier national : %s lieux", len(lieux))

    # Capture brute (couche source) AVANT toute transformation : inclut les
    # lignes rejetées ensuite (id > 2000 octets, code_insee absent) et tous
    # les champs du fichier (pas seulement DTYPE_CARTO). source_key = colonne
    # `source` de chaque lieu.
    if source_sink:
        try:
            par_source = {}
            for lieu in lieux:
                par_source.setdefault(lieu.get("source") or "", []).append(lieu)
            for source_key, records in par_source.items():
                source_sink(records, source_key)
        except Exception:
            logging.error("[source] échec capture carto", exc_info=True)

    # Transformation pure (etl/core/carto.py, fiche 16) : dérivation
    # structure_coop_id, rejets (id > 2000 octets, code_insee absent),
    # restriction aux colonnes du silver.
    df, rejets = transformer_lieux(lieux, set(DTYPE_CARTO))

    # Quarantaine (fiche 03) : les lignes écartées partent dans staging.rejets
    # au lieu d'un drop silencieux. Le sink avale ses erreurs.
    if rejets_sink and rejets:
        rejets_sink(rejets)

    # Matérialisation silver : TRUNCATE + INSERT dans staging.carto__structures.
    colonnes = [col for col in DTYPE_CARTO if col in df.columns]
    lignes = [
        tuple([run_id] + [None if pd.isna(v) else str(v) for v in rec])
        for rec in df[colonnes].itertuples(index=False, name=None)
    ]
    hook = PostgresHook(postgres_conn_id=conn_id)
    conn = hook.get_conn()
    try:
        with conn.cursor() as cursor:
            # Garde volumétrique (SEPT #1724) AVANT le TRUNCATE : un fichier
            # tronqué ferait déréférencer en masse les lieux absents par
            # integration_lieux. Le run échoue ici, le silver précédent reste
            # intact et rien n'atteint main.
            cursor.execute(
                "SELECT count(*) FROM main.lieu_inclusion "
                "WHERE structure_cartographie_nationale_id IS NOT NULL"
            )
            nb_reference = cursor.fetchone()[0]
            erreur = controler_volumetrie(len(df), nb_reference, seuil_volumetrique)
            if erreur:
                raise ValueError(erreur)

            cursor.execute("TRUNCATE staging.carto__structures")
            execute_values(
                cursor,
                "INSERT INTO staging.carto__structures (run_id, {}) VALUES %s".format(
                    ", ".join(colonnes)
                ),
                lignes,
                page_size=1000,
            )
        conn.commit()
    finally:
        conn.close()
    logging.info("Chargé %s lignes dans staging.carto__structures", len(df))
    return len(df)
