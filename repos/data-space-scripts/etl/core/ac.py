"""Core pur du flux Aidants Connect quotidien (fiche 16, FCIS).

Réplique la transformation de APIClientOperator._transform_data pour les
data_type "aidants-personnes" et "aidants-structures" : fonctions pures,
sans dépendance airflow / psycopg2 / requests.

Entrée : items bruts de l'API (contenu de `results`, tel que capturé dans
source.ac__aidants / source.ac__structures). Sortie : listes de dicts aux
colonnes attendues par l'aval (XCom du DAG aidants-connect-import).
"""

from datetime import date
from typing import Any

from etl.core.coop import parse_timestamp
from etl.core.coop import to_pg_array
from etl.core.enrichissement import cle_geocodage
from etl.core.enrichissement import normaliser_siret
from etl.core.enrichissement import siret_valide
from etl.core.rejets import Rejet
from etl.transform.normalizer_utils import normalize_address
from etl.transform.normalizer_utils import normalize_nom
from etl.transform.normalizer_utils import normalize_prenom
from etl.transform.normalizer_utils import validate_pivot


def transformer_aidants(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Items bruts fne_aidants → lignes aidants (colonnes AC_AIDANTS_IMPORT_COLS)."""
    aidants = []
    for item in items:
        org = item.get("organisation", {})
        org_id = str(org.get("uuid")).strip() if org.get("uuid") else None
        aidants.append(
            {
                "aidant_connect_id": item.get("id"),
                "updated_at_ac": parse_timestamp(item.get("updated_at")),
                "prenom": normalize_prenom(item.get("first_name")),
                "nom": normalize_nom(item.get("last_name")),
                "is_active_ac": item.get("is_active"),
                "formation_fne_ac": item.get("formation_fne"),
                "profession_ac": item.get("profession"),
                "nb_accompagnements_ac": item.get("get_supports_number"),
                "is_referent_ac": item.get("is_manager", False),
                "structure_ac_id": org_id,
            }
        )
    return aidants


# Fenêtre glissante get_supports_number_last_six_months : index "0" = mois
# courant (mois du fetch), "5" = M-5.
NB_MOIS_FENETRE = 6


def _mois_moins(mois: date, n: int) -> date:
    """Premier jour du mois situé n mois avant `mois`."""
    total = mois.year * 12 + mois.month - 1 - n
    return date(total // 12, total % 12 + 1, 1)


def transformer_accompagnements(
    items: list[dict[str, Any]], mois_courant: date
) -> tuple[list[dict[str, Any]], list[Rejet]]:
    """Items bruts fne_aidants → (lignes (aidant, mois) → nb, rejets).

    `mois_courant` = mois du fetch (l'index 0 de la fenêtre glissante).
    Dédupliqué sur (aidant_connect_id, mois) : en cas de doublon (retry de
    fetch), la dernière occurrence gagne. Un item sans id devient un ``Rejet``
    (motif ``item_sans_id``, payload = item brut) destiné à ``staging.rejets``
    (fiche 03 : pas de drop silencieux) ; les mois sans valeur restent
    ignorés (sparsité normale de la fenêtre glissante, pas un rejet qualité).
    """
    rows: dict[tuple[int, date], dict[str, Any]] = {}
    rejets: list[Rejet] = []
    for item in items:
        ac_id = item.get("id")
        if ac_id is None:
            rejets.append(Rejet(motif="item_sans_id", payload=item))
            continue
        supports = item.get("get_supports_number_last_six_months") or {}
        for index in range(NB_MOIS_FENETRE):
            valeur = supports.get(str(index))
            if valeur is None:
                continue
            mois = _mois_moins(mois_courant, index)
            rows[(int(ac_id), mois)] = {
                "aidant_connect_id": int(ac_id),
                "mois": mois,
                "nb_accompagnements": int(valeur),
            }
    return list(rows.values()), rejets


def transformer_structures(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Items bruts fne_organisations → lignes structures (AC_STRUCTURES_IMPORT_COLS)."""
    structures = []
    for org in items:
        fr_label = org.get("france_services_label")
        dispositifs = ["France Services"] if fr_label else None
        structures.append(
            {
                "structure_ac_id": org.get("uuid"),
                "updated_at_ac": parse_timestamp(org.get("updated_at")),
                "is_active_ac": org.get("is_active"),
                "nom": org.get("name") if org.get("name") else None,
                "siret": validate_pivot(org.get("siret")),
                "nom_commune": org.get("city") if org.get("city") else None,
                "code_postal": org.get("zipcode") if org.get("zipcode") else None,
                "code_insee": (
                    org.get("city_insee_code") if org.get("city_insee_code") else None
                ),
                "adresse": (
                    normalize_address(org.get("address"))
                    if org.get("address")
                    else None
                ),
                "nb_mandats_ac": org.get("num_mandats"),
                "dispositif_programmes_nationaux": to_pg_array(dispositifs),
            }
        )
    return structures


# === Consolidation silver ⋈ caches d'enrichissement (lot 2 caches, fiche 05) ==
#
# Remplace la relecture de new_structures_enriched.csv : reproduit la forme que
# produisait _enrich_chunk_sirene_ban (aidants-connect-dag.py) à partir des
# lignes de staging.ac__structures et des hits des caches staging.*__cache,
# SAUF écart décidé et tracé (changelog 2026-07-30) : les géocodages invalides
# (score < 0.5, mismatch INSEE) ne sont plus consommés — le cache ne contient
# que les géocodages valides.

# Valeurs SIRENE reprises telles quelles du cache (mêmes colonnes que
# l'ex-_enrich_chunk_sirene_ban ; le silver AC n'en porte aucune → hit ou None).
_COLONNES_SIRENE = [
    "etat_administratif",
    "code_activite_principale",
    "categorie_juridique",
    "denomination_sirene",
    "adresse_sirene",
    "code_insee_sirene",
]

# Valeurs géocodage reprises telles quelles du cache.
_COLONNES_GEOCODAGE = [
    "numero_voie",
    "nom_voie",
    "geom",
    "clef_interop",
    "code_ban",
]


def normaliser_code_postal(val: Any) -> str | None:
    """Réplique le _normalize_cp du DAG AC : CP à 5 chiffres.

    L'API AC envoie le CP sans zéro initial (`1110` → `01110`) ; sans ce zfill
    le filtre postcode de la BAN ne matche pas. Seules les valeurs purement
    numériques sont zfillées. None / NaN → None.
    """
    if val is None or (isinstance(val, float) and val != val):
        return None
    s = str(val).strip()
    if s.endswith(".0"):
        s = s[:-2]
    return s.zfill(5) if s.isdigit() else s


def cle_geocodage_structure_ac(ligne: dict[str, Any]) -> tuple[str, str, str] | None:
    """Clé du cache géocodage pour une ligne silver AC, telle que soumise à
    l'API par le flux : adresse strippée + code_postal normalisé (pas de
    code_insee — celui d'AC est pollué, cf _enrich_chunk_sirene_ban).
    None si la ligne n'a pas d'adresse (jamais géocodée)."""
    adresse = ligne.get("adresse")
    adresse = "" if adresse is None else str(adresse).strip()
    if not adresse:
        return None
    return cle_geocodage(
        adresse, code_postal=normaliser_code_postal(ligne.get("code_postal"))
    )


def consolider_structures_ac(
    lignes: list[dict[str, Any]],
    hits_sirene: dict[str, dict[str, Any]],
    hits_geocodage: dict[tuple[str, str, str], dict[str, Any]],
) -> list[dict[str, Any]]:
    """Lignes silver AC + hits caches → lignes 'enrichies' (ex CSV nouvelles).

    Consolidations héritées de _enrich_chunk_sirene_ban :
    - code_postal : normalisé à 5 chiffres, puis priorité au résultat
      géocodage, fallback source ;
    - nom_commune / code_insee : priorité géocodage, fallback source ;
    - repetition : toujours None ; departement non produit (non consommé) ;
    - colonnes SIRENE / géocodage à None sans hit — ingest_structures retombe
      alors sur son chemin dégradé (adresse source brute), comme avant.
    """
    resultats = []
    for ligne in lignes:
        r = dict(ligne)

        siret = normaliser_siret(ligne.get("siret"))
        hit_sirene = hits_sirene.get(siret) if siret_valide(siret) else None
        for col in _COLONNES_SIRENE:
            r[col] = (hit_sirene or {}).get(col)

        r["code_postal"] = normaliser_code_postal(ligne.get("code_postal"))
        cle = cle_geocodage_structure_ac(ligne)
        hit_geo = hits_geocodage.get(cle) if cle else None
        for col in _COLONNES_GEOCODAGE:
            r[col] = (hit_geo or {}).get(col)

        if hit_geo and hit_geo.get("nom_commune") is not None:
            r["nom_commune"] = hit_geo["nom_commune"]
        if hit_geo and hit_geo.get("code_postal_geocode") is not None:
            r["code_postal"] = hit_geo["code_postal_geocode"]
        if hit_geo and hit_geo.get("code_insee_geocode") is not None:
            r["code_insee"] = hit_geo["code_insee_geocode"]
        r["repetition"] = None

        resultats.append(r)
    return resultats
