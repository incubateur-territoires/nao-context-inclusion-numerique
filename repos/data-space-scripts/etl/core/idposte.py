"""Core idposte : consolidation silver ⋈ caches d'enrichissement (fiche 05).

Remplace la relecture de structure_enriched.csv (lot 2 caches, 2026-07-30) :
reproduit la forme que produisait le chemin 'base' de l'ex
etl/structure_enrichment.py (_process_base_data_batch) à partir des lignes de
staging.idposte__structure et des hits des caches staging.*__cache, SAUF écart
décidé et tracé (changelog 2026-07-30) : les géocodages invalides
(score < 0.5, mismatch INSEE) ne sont plus consommés — le cache ne contient
que les géocodages valides.

Functional core (approche-data/16) : aucune I/O. Entrées = dicts natifs
(lignes silver relues par le DAG, hits des caches), sortie = dicts aux
colonnes consommées par process_enriched_structure.

Le contrat exact est fixé par tests-unitaires/idposte/.
"""

from typing import Any

from etl.core.enrichissement import cle_geocodage
from etl.core.enrichissement import normaliser_siret
from etl.core.enrichissement import siret_valide

# Valeurs SIRENE reprises telles quelles du cache (mêmes colonnes que
# l'ex-chemin 'base' ; adresse_sirene / code_insee_sirene ne sont pas
# consommées par le lecteur mais conservées par fidélité de forme).
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
    "nom_commune",
    "geom",
    "clef_interop",
    "code_ban",
]


def cle_geocodage_structure(ligne: dict[str, Any]) -> tuple[str, str, str] | None:
    """Clé du cache géocodage pour une ligne silver, telle que soumise à l'API
    par le flux idposte : adresse strippée + code_insee (pas de code_postal).
    None si la ligne n'a pas d'adresse (jamais géocodée)."""
    adresse = ligne.get("adresse")
    adresse = "" if adresse is None else str(adresse).strip()
    if not adresse:
        return None
    return cle_geocodage(adresse, code_insee=ligne.get("code_insee"))


def consolider_structures(
    lignes: list[dict[str, Any]],
    hits_sirene: dict[str, dict[str, Any]],
    hits_geocodage: dict[tuple[str, str, str], dict[str, Any]],
) -> list[dict[str, Any]]:
    """Lignes silver + hits caches → lignes 'enrichies' (ex structure_enriched.csv).

    Consolidations héritées du chemin 'base' :
    - code_postal / code_insee : priorité au résultat géocodage, fallback source ;
    - repetition : toujours None ;
    - colonnes SIRENE / géocodage à None quand pas de hit (SIRET absent du
      référentiel, adresse non géocodée validement) — le filtre adresse du
      lecteur écarte ensuite ces lignes, comme avant.
    """
    resultats = []
    for ligne in lignes:
        r = dict(ligne)

        siret = normaliser_siret(ligne.get("siret"))
        hit_sirene = hits_sirene.get(siret) if siret_valide(siret) else None
        for col in _COLONNES_SIRENE:
            r[col] = (hit_sirene or {}).get(col)

        cle = cle_geocodage_structure(ligne)
        hit_geo = hits_geocodage.get(cle) if cle else None
        for col in _COLONNES_GEOCODAGE:
            r[col] = (hit_geo or {}).get(col)

        if hit_geo and hit_geo.get("code_postal_geocode") is not None:
            r["code_postal"] = hit_geo["code_postal_geocode"]
        if hit_geo and hit_geo.get("code_insee_geocode") is not None:
            r["code_insee"] = hit_geo["code_insee_geocode"]
        r["repetition"] = None

        resultats.append(r)
    return resultats
