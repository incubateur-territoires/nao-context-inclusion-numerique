"""Core BAN : transformation pure des réponses de géocodage.

Functional core (approche-data/16) : aucune I/O ici. L'entrée est la forme
brute capturée dans source.ban__adresses (une ligne du CSV de réponse
/search/csv, valeurs str | None — cf. contracts/ban__adresses.yml) ; la
sortie, des lignes (dicts) aux colonnes produites par
GeocodeurBatch.geocoder_dataframe.

Comportement aligné sur le legacy `_geocoder_batch` (etl/geocoding_batch.py),
SAUF correction décidée et tracée (MR 2 boucle BAN, approche-data/17) :
- code_ban lit `result_banId` (casse réelle de l'API — le legacy lisait
  `result_banid` en minuscules, clef inexistante, 100 % None).

Le contrat exact est fixé par tests-unitaires/ban/.
"""

from typing import Any

SCORE_MINIMUM_DEFAUT = 0.5

_COLONNES = [
    "id_source",
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
    "geocodage_valide",
    "clef_interop",
    "code_ban",
]


def ligne_vide(id_source: str) -> dict[str, Any]:
    """Résultat vide (mismatch INSEE, erreur API) : tout None sauf id_source."""
    ligne: dict[str, Any] = {colonne: None for colonne in _COLONNES}
    ligne["id_source"] = id_source
    ligne["geocodage_valide"] = False
    return ligne


def _code_insee_propre(value: str | None) -> str:
    """Valeur INSEE comparable : '' si absente ('', None, 'nan'), sinon strip."""
    if value is None:
        return ""
    value = str(value).strip()
    if value.lower() == "nan":
        return ""
    return value


def _float_ou_none(value: str | float | None) -> float | None:
    if value is None:
        return None
    return float(value)


def transformer_reponses(
    records: list[dict[str, Any]], score_minimum: float = SCORE_MINIMUM_DEFAUT
) -> list[dict[str, Any]]:
    """Lignes brutes du CSV de réponse BAN → lignes de résultat géocodage.

    Une ligne de sortie par ligne d'entrée. Si le code INSEE demandé et celui
    du résultat existent et diffèrent, le résultat entier est rejeté (ligne
    vide) — comportement legacy conservé, documenté au contrat.
    """
    lignes = []
    for record in records:
        insee_demande = _code_insee_propre(record.get("code_insee"))
        insee_resultat = _code_insee_propre(record.get("result_citycode"))
        if insee_demande and insee_resultat and insee_demande != insee_resultat:
            lignes.append(ligne_vide(record["id_source"]))
            continue

        # Comportement legacy conservé : une valeur illisible annule
        # longitude, latitude ET score d'un bloc.
        try:
            longitude = _float_ou_none(record.get("longitude"))
            latitude = _float_ou_none(record.get("latitude"))
            score = _float_ou_none(record.get("result_score"))
        except (ValueError, TypeError):
            longitude = latitude = score = None

        lignes.append(
            {
                "id_source": record["id_source"],
                "code_insee_geocode": record.get("result_citycode") or None,
                "numero_voie": record.get("result_housenumber") or None,
                "nom_voie": record.get("result_street") or None,
                "nom_commune": record.get("result_city") or None,
                "code_postal_geocode": record.get("result_postcode") or None,
                "longitude": longitude,
                "latitude": latitude,
                "score_geocodage": score,
                "label_geocodage": record.get("result_label") or None,
                # Comportement legacy conservé : pas de geom si une
                # coordonnée est absente (ou vaut 0, valeur falsy).
                "geom": (
                    f"POINT({longitude} {latitude})" if longitude and latitude else None
                ),
                "geocodage_valide": score is not None and score >= score_minimum,
                "clef_interop": record.get("result_id") or None,
                "code_ban": record.get("result_banId") or None,
            }
        )
    return lignes
