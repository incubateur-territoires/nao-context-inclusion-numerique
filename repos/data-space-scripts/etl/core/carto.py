"""Core carto : transformation pure du fichier national mednum-cli.

Functional core (approche-data/16) : aucune I/O ici. L'entrée est la forme
brute capturée dans source.carto__structures (les lieux du fichier national
dédupliqué, schéma data-inclusion — cf. contracts/carto__structures.yml) ;
la sortie, le DataFrame prêt à matérialiser dans staging.carto__structures.

Comportement aligné sur le legacy `load_carto_national_file`
(etl/load/load_to_postgresql.py), sans correction à ce stade. Le contrat
exact est fixé par tests-unitaires/carto/.
"""

import logging
import re
from typing import Any
from typing import Iterable

import pandas as pd

from etl.core.rejets import Rejet

# Ids coop STANDALONE uniquement : l'uuid EST le structure_coop_id. Les ids
# COMPOSÉS 'Coop-numérique_<uuid>__<autre>' (lieux fusionnés lors de la dédup
# nationale) gardent structure_coop_id vide, comme mednum-cli — leur
# réconciliation relève d'une vraie fusion (cf. ticket dédié).
_COOP_RX = re.compile(r"^Coop-numérique_([0-9a-fA-F-]{36})$")

# Au-delà de 2000 octets, l'INSERT dans main.lieu_inclusion viole l'index btree
# sur structure_cartographie_nationale_id (max ~2704 octets).
_ID_MAX_OCTETS = 2000

logger = logging.getLogger(__name__)


def transformer_lieux(
    lieux: list[dict[str, Any]], colonnes_autorisees: Iterable[str]
) -> tuple[pd.DataFrame, list[Rejet]]:
    """Lieux bruts du fichier national → DataFrame prêt pour le silver.

    Args:
        lieux: liste de dicts, un par lieu (forme source.carto__structures).
        colonnes_autorisees: colonnes de staging.carto__structures (clefs de
            DTYPE_CARTO), injectées par le shell.

    Returns:
        Tuple (DataFrame restreint aux colonnes autorisées — ordre du fichier,
        structure_coop_id dérivé en dernier —, rejets). Chaque ligne écartée
        (id > 2000 octets UTF-8, code_insee absent) devient un ``Rejet``
        portant le lieu brut complet, destiné à ``staging.rejets`` (fiche 03 :
        pas de drop silencieux).
    """
    df = pd.DataFrame(lieux)
    if df.empty or "id" not in df.columns:
        raise ValueError("Fichier national vide ou sans colonne 'id'")

    rejets: list[Rejet] = []

    def rejeter(indices: Iterable[int], motif: str) -> None:
        # L'index du DataFrame (RangeIndex, préservé par les .loc) est la
        # position dans `lieux` : on remonte au dict brut d'origine.
        for i in indices:
            brut = lieux[i]
            rejets.append(
                Rejet(
                    motif=motif,
                    payload=brut,
                    source_key=brut.get("source") or None,
                )
            )

    # structure_coop_id reconstruit depuis l'id, en écrasant le champ
    # éventuellement fourni (data.gouv le pré-remplit, CloudFront non).
    df["structure_coop_id"] = df["id"].astype(str).str.extract(_COOP_RX, expand=False)

    id_bytes = df["id"].fillna("").map(lambda s: len(s.encode("utf-8")))
    mask_too_long = id_bytes > _ID_MAX_OCTETS
    if mask_too_long.any():
        logger.warning(
            "Rejet de %s lignes avec id > %s octets (max=%s)",
            int(mask_too_long.sum()),
            _ID_MAX_OCTETS,
            int(id_bytes.max()),
        )
        rejeter(df.index[mask_too_long], "id_trop_long")
        df = df.loc[~mask_too_long].copy()

    # Sans code_insee, main.adresse.code_insee (NOT NULL) ferait échouer
    # integration_adresses — pas d'étape de géocodage BAN sur ce flux.
    if "code_insee" in df.columns:
        no_insee = df["code_insee"].isna() | (
            df["code_insee"].astype(str).str.strip() == ""
        )
        if no_insee.any():
            logger.warning(
                "Rejet de %s lignes sans code_insee (pas de géocodage BAN)",
                int(no_insee.sum()),
            )
            rejeter(df.index[no_insee], "code_insee_absent")
            df = df.loc[~no_insee].copy()

    colonnes_autorisees = set(colonnes_autorisees)
    return df[[col for col in df.columns if col in colonnes_autorisees]], rejets


def controler_volumetrie(
    nb_entrants: int, nb_reference: int, seuil: float
) -> str | None:
    """Garde volumétrique du fichier national (SEPT #1724).

    Un fichier national tronqué (erreur amont, publication partielle) ferait
    déréférencer en masse les lieux absents (`visible = FALSE`, carto_id
    NULL) par integration_lieux. On refuse donc le run si le volume entrant
    chute anormalement par rapport aux lieux carto déjà en base.

    Args:
        nb_entrants: lignes prêtes à être matérialisées dans le silver.
        nb_reference: lieux actuellement référencés carto en base
            (structure_cartographie_nationale_id NOT NULL).
        seuil: fraction minimale attendue (ex. 0.8 = tolère -20 %).

    Returns:
        None si le volume est acceptable (ou bootstrap : nb_reference <= 0),
        sinon le message d'erreur à faire porter par l'échec du run.
    """
    if nb_reference <= 0:
        return None
    if nb_entrants >= nb_reference * seuil:
        return None
    return (
        f"Garde volumétrique : {nb_entrants} lieux entrants pour "
        f"{nb_reference} lieux carto en base, sous le seuil de {seuil:.0%} "
        f"({nb_reference * seuil:.0f} attendus au minimum). Fichier national "
        "probablement tronqué — run refusé avant TRUNCATE du silver."
    )
