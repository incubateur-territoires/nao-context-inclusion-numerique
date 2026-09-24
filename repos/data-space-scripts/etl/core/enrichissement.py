"""Core enrichissement : normalisations pures des clés de cache (fiche 05, V137).

Les caches staging.sirene__cache / staging.geocodage__cache sont adressés par
la clé EXACTEMENT soumise à l'API (SIRET normalisé, triplet adresse/citycode/
postcode). Ces normalisations vivent ici en fonctions pures pour être
partagées entre les écrivains (etl/enrichment_cache.py, wrappers cache-first)
et les lecteurs (jointure silver ⋈ caches côté ingest) sans dupliquer la
logique — les shells (SireneBatch, enrichment_cache) délèguent ici.

Functional core (approche-data/16) : aucune I/O, aucun pandas. Les NaN pandas
sont détectés par l'identité NaN != NaN (les appelants shell peuvent aussi
convertir en None en amont).
"""

from typing import Any

from etl.core.rejets import Rejet


def _est_nan(valeur: Any) -> bool:
    return isinstance(valeur, float) and valeur != valeur


def normaliser_siret(siret: Any) -> str:
    """SIRET tel que soumis à l'API SIRENE (réplique SireneBatch._normalize_siret).

    Chaîne de 14 chiffres (zfill), '' si invalide (non numérique, > 14 chars,
    absent). Le SIRET placeholder '00000000000000' reste filtré par les
    appelants (comme dans SireneBatch.enrichir_dataframe).
    """
    if siret is None or _est_nan(siret):
        return ""

    if isinstance(siret, float):
        siret = str(int(siret))
    elif (
        isinstance(siret, str)
        and siret.endswith(".0")
        and siret.replace(".", "").isdigit()
    ):
        siret = siret[:-2]
    else:
        siret = str(siret)

    siret = siret.strip()
    if siret.isdigit() and len(siret) <= 14:
        return siret.zfill(14)
    return ""


def siret_valide(siret_normalise: str) -> bool:
    """Même filtre que SireneBatch.enrichir_dataframe après normalisation."""
    return len(siret_normalise) == 14 and siret_normalise != "00000000000000"


def nettoyer_code(valeur: Any) -> str:
    """Code INSEE/postal tel que soumis à l'API BAN (réplique clean_code de
    GeocodeurBatch) : '' si absent, sinon strip + suppression du suffixe '.0'."""
    if valeur is None or valeur == "" or _est_nan(valeur):
        return ""
    s = str(valeur).strip()
    if s.endswith(".0"):
        s = s[:-2]
    return s


def cle_geocodage(
    adresse: Any, code_insee: Any = None, code_postal: Any = None
) -> tuple[str, str, str]:
    """Clé du cache géocodage : triplet exactement soumis à l'API.

    L'adresse est prise telle quelle (str) — c'est à l'appelant de reproduire
    la préparation du flux (strip côté idposte/AC/coop : adresse_recherche).
    """
    a = "" if adresse is None or _est_nan(adresse) else str(adresse)
    return (a, nettoyer_code(code_insee), nettoyer_code(code_postal))


def rejets_geocodage(lignes: list[dict[str, Any]]) -> list[Rejet]:
    """Géocodages invalides → rejets pour staging.rejets (fiche 03).

    `lignes` = géocodages écartés par le batch (geocodage_valide=False),
    portant la clé soumise à l'API (adresse, code_insee, code_postal) et le
    score. Deux motifs, distingués par le score :
    - score présent → résultat sous le seuil : ``geocodage_score_faible`` ;
    - score absent → aucun résultat BAN, code INSEE discordant ou réponse
      illisible : ``geocodage_sans_resultat``.
    La ligne entière devient le payload, id_source la source_key.
    """
    rejets = []
    for ligne in lignes:
        score = ligne.get("score_geocodage")
        id_source = ligne.get("id_source")
        rejets.append(
            Rejet(
                motif=(
                    "geocodage_sans_resultat"
                    if score is None or _est_nan(score)
                    else "geocodage_score_faible"
                ),
                payload=ligne,
                source_key=str(id_source) if id_source is not None else None,
            )
        )
    return rejets
