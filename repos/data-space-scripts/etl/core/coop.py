"""Core coop-numerique : transformations pures source.* → lignes finales.

Functional core (approche-data/16) : aucune I/O ici. L'entrée est la forme
brute capturée dans source.coop__* (donnee JSONB : {"id", "attributes": {...}},
cf. contracts/coop__*.yml) ; la sortie, des lignes (dicts) aux colonnes de la
chaîne d'ingest existante.

Comportement aligné sur le legacy `_transform_data` (http_airflow.py).

#1805 : les activités ne passent plus par ce core — main.activites_coop est
une vue sur coop.activites (V144). V159 : les structures non plus — la vue
d'union main.lieu_inclusion lit coop.lieu_inclusion en direct, l'identité du
registre est maintenue par etl/load/registre_lieux_coop.py (SQL direct).
Ne reste que transformer_utilisateurs (silver sans consommateur, à retirer).

Le contrat exact est fixé par tests-unitaires/coop/.
"""

from typing import Any

import pandas as pd

from etl.transform.normalizer_utils import format_and_validate_phone
from etl.transform.normalizer_utils import normalize_nom
from etl.transform.normalizer_utils import normalize_prenom

def parse_timestamp(value: str | None) -> str | None:
    """Timestamp source (tz quelconque) → chaîne UTC naïve, ou None si illisible."""
    if not value:
        return None
    ts = pd.to_datetime(value, utc=True, errors="coerce")
    if pd.isna(ts):
        return None
    ts = ts.tz_convert("UTC").tz_localize(None)
    return ts.strftime("%Y-%m-%d %H:%M:%S.%f")


def to_pg_array(value: list[Any] | None) -> str | None:
    """Liste → littéral pg-array "{a,b}" (liste vide → None).

    Comportement legacy conservé : pas d'échappement pg, les virgules internes
    d'un label sont supprimées (perte documentée au contrat).
    """
    if isinstance(value, list):
        if not value:
            return None
        cleaned = [str(v).replace(",", "") for v in value]
        return "{" + ",".join(cleaned) + "}"
    return value


def _contact_utilisateur(attributes: dict[str, Any]) -> dict[str, Any]:
    """Contact utilisateur : dict {"coop": {email, telephone}} ou {} si vide.

    Comportement legacy conservé : contrairement aux structures, le contact
    utilisateur est un dict (pas une chaîne JSON).
    """
    email = (attributes.get("email") or "").strip() or None
    telephone = format_and_validate_phone(attributes.get("telephone")) or None
    coop: dict[str, Any] = {}
    if email:
        coop["email"] = email
    if telephone:
        coop["telephone"] = telephone
    return {"coop": coop} if coop else {}


def transformer_utilisateurs(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Objets bruts de source.coop__utilisateurs → lignes utilisateurs coop.

    Comportement identique au legacy — is_visible lu sous
    attributes.mediateur.is_visible (fix 9d19646), affectations lieu portant
    "fin" (et non "suppression"), emplois exclus si le conseiller numérique est
    complet (id ET id_pg : la structure d'emploi vient alors du flux CN).
    """
    lignes = []
    for item in items:
        attributes = item.get("attributes", {})
        coop_id = item.get("id")
        conseiller_numerique = attributes.get("conseiller_numerique") or {}
        mediateur = attributes.get("mediateur") or {}
        coordinateur = attributes.get("coordinateur") or {}

        cn_pg_id = conseiller_numerique.get("id_pg") or None
        conseiller_numerique_id = conseiller_numerique.get("id") or None

        activites_entries = [
            {
                "mediateur_coop_id": coop_id,
                "structure_coop_id": activite.get("structure_id"),
                "fin": activite.get("fin"),
                "type": "lieu_activite",
            }
            for activite in (mediateur.get("en_activite") or [])
        ]
        emplois_entries = []
        if cn_pg_id is None or conseiller_numerique_id is None:
            emplois_entries = [
                {
                    "mediateur_coop_id": coop_id,
                    "structure_coop_id": emploi.get("structure_id"),
                    "fin": emploi.get("fin"),
                    "type": "structure_emploi",
                }
                for emploi in (attributes.get("emplois") or [])
            ]

        lignes.append(
            {
                "coop_id": coop_id,
                "updated_at_coop": parse_timestamp(attributes.get("modification")),
                "deleted_at_coop": parse_timestamp(attributes.get("suppression")),
                "nom": normalize_nom(attributes.get("nom")) or None,
                "prenom": normalize_prenom(attributes.get("prenom")) or None,
                "contact": _contact_utilisateur(attributes),
                "cn_pg_id": cn_pg_id,
                "is_visible": mediateur.get("is_visible"),
                "conseiller_numerique_id": conseiller_numerique_id,
                "is_mediateur": bool(mediateur.get("id")),
                "is_coordinateur": bool(coordinateur.get("id")),
                "personne_affectations": emplois_entries + activites_entries,
                # V157 (#1707) : plus de coordination_mediation — la table
                # répliquée est supprimée, coop.mediateurs_coordonnes fait foi.
            }
        )
    return lignes


def dedupe_par_id(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Dernière occurrence par `id` (ordre de première apparition conservé).

    Un retry du fetch peut capturer deux fois la même page dans source.*
    (append-only) : on ne garde que la version la plus récente de chaque objet.
    """
    par_id: dict[Any, dict[str, Any]] = {}
    for item in items:
        par_id[item.get("id")] = item
    return list(par_id.values())
