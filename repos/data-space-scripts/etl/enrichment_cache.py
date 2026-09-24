"""Caches d'enrichissement SIRENE / géocodage (fiche 05, V137).

Wrappers *cache-first* autour de `SireneBatch` et `GeocodeurBatch` : mêmes
signatures et mêmes colonnes de sortie que les batchs sous-jacents, mais chaque
clé d'entrée (SIRET normalisé, triplet adresse/citycode/postcode soumis à
l'API) est d'abord cherchée dans `staging.sirene__cache` /
`staging.geocodage__cache`. Seules les clés manquantes ou périmées (TTL
4 mois, aligné sur le gate `last_sirene_enrich_at` d'AC/coop) partent à l'API,
et leurs résultats *utiles* (établissement trouvé, géocodage valide) sont
upsertés dans le cache (write-through). Les échecs et absences ne sont pas
cachés : ils restent re-tentés à chaque run, comme avant.

Le cache est best-effort, comme la capture bronze (etl/source_capture.py) :
toute erreur SQL est avalée (rollback + log) et le flux retombe sur l'appel
API complet — jamais d'interruption de pipeline, jamais de résultat dégradé.
"""

import logging

import pandas as pd
from psycopg2.extras import execute_values

from etl.core.enrichissement import nettoyer_code
from etl.core.enrichissement import rejets_geocodage

logger = logging.getLogger(__name__)

TTL_MOIS = 4
_LOOKUP_CHUNK = 5000

SIRENE_CACHE_TABLE = "staging.sirene__cache"
GEOCODAGE_CACHE_TABLE = "staging.geocodage__cache"

# Colonnes de valeurs du cache SIRENE = sortie de SireneBatch.enrichir_dataframe
# moins (id_source, siret_sirene, sirene_trouve).
_VALEURS_SIRENE = [
    "etat_administratif",
    "code_activite_principale",
    "categorie_juridique",
    "denomination_sirene",
    "adresse_sirene",
    "code_insee_sirene",
    "code_postal_sirene",
    "date_creation_sirene",
    "tranche_effectifs_sirene",
]
_COLONNES_SIRENE = ["id_source", "siret_sirene"] + _VALEURS_SIRENE + ["sirene_trouve"]

# Colonnes de valeurs du cache géocodage = sortie du core BAN
# (etl/core/ban.py:transformer_reponses) moins (id_source, geocodage_valide).
_VALEURS_GEOCODAGE = [
    "code_insee_geocode",
    "numero_voie",
    "nom_voie",
    "nom_commune",
    "code_postal_geocode",
    "longitude",
    "latitude",
    "score_geocodage",
    "label_geocodage",
    "geom",
    "clef_interop",
    "code_ban",
]
_COLONNES_GEOCODAGE = ["id_source"] + _VALEURS_GEOCODAGE + ["geocodage_valide"]


def _lookup(conn, table, colonnes_cle, cles, colonnes_valeurs):
    """Entrées fraîches du cache : {tuple clé: dict valeurs}. {} sur erreur."""
    if not cles:
        return {}
    sql = (
        f"SELECT {', '.join(list(colonnes_cle) + colonnes_valeurs)} FROM {table} "
        f"WHERE ({', '.join(colonnes_cle)}) IN %s "
        f"AND enriched_at >= now() - interval '{TTL_MOIS} months'"
    )
    resultat = {}
    try:
        with conn.cursor() as cur:
            for i in range(0, len(cles), _LOOKUP_CHUNK):
                cur.execute(sql, (tuple(cles[i : i + _LOOKUP_CHUNK]),))
                for row in cur.fetchall():
                    cle = tuple(row[: len(colonnes_cle)])
                    resultat[cle] = dict(
                        zip(colonnes_valeurs, row[len(colonnes_cle) :])
                    )
        conn.commit()
    except Exception:
        logger.error(
            "[cache] échec lecture %s — repli sur l'appel API complet",
            table,
            exc_info=True,
        )
        conn.rollback()
        return {}
    return resultat


def _upsert(conn, table, colonnes_cle, colonnes_valeurs, rows, run_id):
    """Write-through best-effort : upsert par clé, erreur avalée."""
    if not rows:
        return
    colonnes = list(colonnes_cle) + colonnes_valeurs + ["run_id"]
    sql = (
        f"INSERT INTO {table} ({', '.join(colonnes)}) VALUES %s "
        f"ON CONFLICT ({', '.join(colonnes_cle)}) DO UPDATE SET "
        + ", ".join(f"{c} = EXCLUDED.{c}" for c in colonnes_valeurs + ["run_id"])
        + ", enriched_at = now()"
    )
    try:
        with conn.cursor() as cur:
            execute_values(
                cur, sql, [tuple(r) + (run_id,) for r in rows], page_size=1000
            )
        conn.commit()
        logger.info("[cache] %d entrées upsertées dans %s", len(rows), table)
    except Exception:
        logger.error(
            "[cache] échec écriture %s — cache ignoré", table, exc_info=True
        )
        conn.rollback()


def _sans_nan(valeur):
    return None if pd.isna(valeur) else valeur


def lire_cache_sirene(conn, sirets):
    """Hits frais du cache SIRENE : {siret normalisé: dict valeurs}.

    Lecture seule pour la jointure silver ⋈ cache côté ingest (lot 2) :
    les SIRET doivent être normalisés via etl.core.enrichissement.
    Best-effort comme _lookup ({} sur erreur)."""
    cles = [(s,) for s in dict.fromkeys(sirets)]
    hits = _lookup(conn, SIRENE_CACHE_TABLE, ["siret"], cles, _VALEURS_SIRENE)
    return {cle[0]: valeurs for cle, valeurs in hits.items()}


def lire_cache_geocodage(conn, cles):
    """Hits frais du cache géocodage : {(adresse, insee, postal): dict valeurs}.

    Les clés doivent être les triplets exactement soumis à l'API
    (etl.core.enrichissement.cle_geocodage). Best-effort ({} sur erreur)."""
    return _lookup(
        conn,
        GEOCODAGE_CACHE_TABLE,
        ["adresse", "code_insee", "code_postal"],
        list(dict.fromkeys(cles)),
        _VALEURS_GEOCODAGE,
    )


class SireneAvecCache:
    """SireneBatch cache-first : même `enrichir_dataframe`, même sortie."""

    def __init__(self, conn, run_id, sirene_batch):
        self._conn = conn
        self._run_id = run_id
        self._batch = sirene_batch

    def enrichir_dataframe(self, df, colonne_id, colonne_siret):
        ids = df[colonne_id].astype(str)
        # Même normalisation que le batch sous-jacent : la clé du cache est le
        # SIRET tel qu'il serait soumis à l'API.
        sirets = df[colonne_siret].apply(self._batch._normalize_siret)
        valides = (sirets.str.len() == 14) & (sirets != "00000000000000")

        cles = [(s,) for s in dict.fromkeys(sirets[valides])]
        hits = _lookup(
            self._conn, SIRENE_CACHE_TABLE, ["siret"], cles, _VALEURS_SIRENE
        )

        en_cache = valides & sirets.isin({c[0] for c in hits})
        lignes_cache = [
            {
                "id_source": id_source,
                "siret_sirene": siret,
                **hits[(siret,)],
                "sirene_trouve": True,
            }
            for id_source, siret in zip(ids[en_cache], sirets[en_cache])
        ]

        manquants = valides & ~en_cache
        logger.info(
            "[cache] SIRENE : %d SIRET valides, %d servis par le cache, "
            "%d envoyés à l'API",
            int(valides.sum()),
            int(en_cache.sum()),
            int(manquants.sum()),
        )

        if manquants.any():
            df_api = self._batch.enrichir_dataframe(
                df.loc[manquants], colonne_id, colonne_siret
            )
            # Seuls les établissements trouvés sont cachés : un SIRET absent ou
            # un batch en échec (mêmes colonnes à None) sera re-tenté.
            trouves = df_api[df_api["sirene_trouve"]].drop_duplicates(
                subset=["siret_sirene"], keep="first"
            )
            _upsert(
                self._conn,
                SIRENE_CACHE_TABLE,
                ["siret"],
                _VALEURS_SIRENE,
                [
                    [_sans_nan(v) for v in row]
                    for row in trouves[
                        ["siret_sirene"] + _VALEURS_SIRENE
                    ].itertuples(index=False, name=None)
                ],
                self._run_id,
            )
        else:
            df_api = pd.DataFrame(columns=_COLONNES_SIRENE)

        df_cache = pd.DataFrame(lignes_cache, columns=_COLONNES_SIRENE)
        if len(df_cache) == 0:
            return df_api
        if len(df_api) == 0:
            return df_cache
        return pd.concat([df_cache, df_api], ignore_index=True)


def _nettoyer_code(valeur):
    """Réplique du clean_code de GeocodeurBatch (clé = valeur soumise à l'API)."""
    if pd.isna(valeur):
        return ""
    return nettoyer_code(valeur)


class GeocodeurAvecCache:
    """GeocodeurBatch cache-first : même `geocoder_dataframe`, même sortie.

    `rejets_sink` (optionnel, etl/quarantaine.py) : les géocodages invalides
    retournés par l'API (score sous le seuil, aucun résultat, INSEE
    discordant) — non cachés, donc jusqu'ici invisibles — y sont routés en
    quarantaine (fiche 03)."""

    def __init__(self, conn, run_id, geocodeur_batch, rejets_sink=None):
        self._conn = conn
        self._run_id = run_id
        self._batch = geocodeur_batch
        self._rejets_sink = rejets_sink

    def geocoder_dataframe(
        self,
        df,
        colonne_id,
        colonne_adresse,
        colonne_code_postal=None,
        colonne_code_insee=None,
    ):
        ids = df[colonne_id].astype(str)
        adresses = df[colonne_adresse].fillna("").astype(str)
        insee = (
            df[colonne_code_insee].apply(_nettoyer_code)
            if colonne_code_insee
            else pd.Series("", index=df.index)
        )
        postal = (
            df[colonne_code_postal].apply(_nettoyer_code)
            if colonne_code_postal
            else pd.Series("", index=df.index)
        )
        valides = adresses.str.strip() != ""

        cles_lignes = pd.Series(
            list(zip(adresses, insee, postal)), index=df.index
        )
        cles = list(dict.fromkeys(cles_lignes[valides]))
        hits = _lookup(
            self._conn,
            GEOCODAGE_CACHE_TABLE,
            ["adresse", "code_insee", "code_postal"],
            cles,
            _VALEURS_GEOCODAGE,
        )

        en_cache = valides & cles_lignes.isin(set(hits))
        lignes_cache = [
            {"id_source": id_source, **hits[cle], "geocodage_valide": True}
            for id_source, cle in zip(ids[en_cache], cles_lignes[en_cache])
        ]

        manquants = valides & ~en_cache
        logger.info(
            "[cache] géocodage : %d adresses, %d servies par le cache, "
            "%d envoyées à l'API",
            int(valides.sum()),
            int(en_cache.sum()),
            int(manquants.sum()),
        )

        if manquants.any():
            df_api = self._batch.geocoder_dataframe(
                df.loc[manquants],
                colonne_id=colonne_id,
                colonne_adresse=colonne_adresse,
                colonne_code_postal=colonne_code_postal,
                colonne_code_insee=colonne_code_insee,
            )
            if len(df_api) > 0:
                # Seuls les géocodages valides sont cachés : mismatch INSEE,
                # score faible ou échec API seront re-tentés.
                cle_par_id = dict(zip(ids[manquants], cles_lignes[manquants]))
                valides_api = df_api[df_api["geocodage_valide"]].copy()
                valides_api["_cle"] = valides_api["id_source"].map(cle_par_id)
                valides_api = valides_api[
                    valides_api["_cle"].notna()
                ].drop_duplicates(subset=["_cle"], keep="first")
                _upsert(
                    self._conn,
                    GEOCODAGE_CACHE_TABLE,
                    ["adresse", "code_insee", "code_postal"],
                    _VALEURS_GEOCODAGE,
                    [
                        list(row["_cle"])
                        + [_sans_nan(row[c]) for c in _VALEURS_GEOCODAGE]
                        for _, row in valides_api.iterrows()
                    ],
                    self._run_id,
                )
                if self._rejets_sink is not None:
                    invalides = df_api[~df_api["geocodage_valide"].astype(bool)]
                    lignes_rejet = []
                    for _, row in invalides.iterrows():
                        cle = cle_par_id.get(row["id_source"], ("", "", ""))
                        lignes_rejet.append(
                            {
                                "id_source": row["id_source"],
                                "adresse": cle[0],
                                "code_insee": cle[1],
                                "code_postal": cle[2],
                                "score_geocodage": _sans_nan(
                                    row["score_geocodage"]
                                ),
                                "label_geocodage": _sans_nan(
                                    row["label_geocodage"]
                                ),
                            }
                        )
                    self._rejets_sink(rejets_geocodage(lignes_rejet))
        else:
            df_api = pd.DataFrame(columns=_COLONNES_GEOCODAGE)

        df_cache = pd.DataFrame(lignes_cache, columns=_COLONNES_GEOCODAGE)
        if len(df_cache) == 0:
            return df_api
        if len(df_api) == 0:
            return df_cache
        return pd.concat([df_cache, df_api], ignore_index=True)
