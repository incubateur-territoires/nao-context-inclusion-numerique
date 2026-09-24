"""Validation de contrat de flux (fiche 02) — fonctions pures, mode warn.

Détecte le drift de schéma d'une source par rapport à son contrat
(`contracts/*.yml`) : champ requis absent, champ inconnu, type simple qui
change. Le contrat est chargé par l'appelant (shell Airflow) : ce module ne
fait ni I/O ni yaml — il reçoit le contrat déjà parsé (dict) et les
enregistrements bruts (dicts JSONB de `source.*`), et rend des anomalies
agrégées par champ.

Les types des contrats sont verbeux ("string datetime ISO Z") : seul le
premier mot est vérifié, et uniquement s'il correspond à un type simple
connu — le reste est documentaire.
"""

from collections import Counter
from dataclasses import dataclass

# Types simples vérifiables : 1er mot (minuscule) du champ `type` du contrat.
_TYPES_VERIFIABLES: dict[str, type] = {
    "integer": int,
    "int": int,
    "boolean": bool,
    "bool": bool,
    "string": str,
    "float": float,
    "objet": dict,
    "object": dict,
    "liste": list,
    "array": list,
}


@dataclass(frozen=True)
class Champ:
    nom: str  # chemin JSON, éventuellement pointé ("organisation.uuid")
    requis: bool
    type_simple: type | None  # None = type non vérifiable (documentaire)


@dataclass(frozen=True)
class Anomalie:
    categorie: str  # champ_inconnu | champ_requis_absent | type_inattendu
    champ: str
    nb: int  # enregistrements touchés
    total: int  # enregistrements validés


def parser_champs(contrat: dict) -> list[Champ]:
    """Extrait les champs vérifiables de la section `fields` d'un contrat."""
    champs = []
    for field in contrat.get("fields", []):
        type_brut = str(field.get("type", "")).strip().lower()
        premier_mot = type_brut.split()[0] if type_brut else ""
        champs.append(
            Champ(
                nom=str(field["name"]),
                requis=bool(field.get("required", False)),
                type_simple=_TYPES_VERIFIABLES.get(premier_mot),
            )
        )
    return champs


def _lire(record: dict, chemin: str) -> tuple[bool, object]:
    """Suit un chemin pointé dans le record : (clé présente ?, valeur)."""
    courant: object = record
    for partie in chemin.split("."):
        if not isinstance(courant, dict) or partie not in courant:
            return False, None
        courant = courant[partie]
    return True, courant


def _type_ok(valeur: object, attendu: type) -> bool:
    # Piège python : bool est un sous-type d'int — un booléen n'est conforme
    # qu'à un champ boolean.
    if isinstance(valeur, bool):
        return attendu is bool
    return isinstance(valeur, attendu)


def valider_enregistrements(
    records: list[dict], champs: list[Champ]
) -> list[Anomalie]:
    """Valide des enregistrements bruts contre les champs du contrat.

    Retourne les anomalies agrégées par champ (1 anomalie = 1 champ touché,
    avec compteur), triées par (categorie, champ) — jamais d'exception :
    conçu pour un mode warn.
    """
    total = len(records)
    if total == 0:
        return []
    compteurs: Counter[tuple[str, str]] = Counter()
    connus_top_niveau = {champ.nom.split(".")[0] for champ in champs}
    for record in records:
        for champ in champs:
            present, valeur = _lire(record, champ.nom)
            if not present:
                if champ.requis:
                    compteurs[("champ_requis_absent", champ.nom)] += 1
                continue
            if (
                champ.type_simple is not None
                and valeur is not None
                and not _type_ok(valeur, champ.type_simple)
            ):
                compteurs[("type_inattendu", champ.nom)] += 1
        for cle in record:
            if cle not in connus_top_niveau:
                compteurs[("champ_inconnu", cle)] += 1
    return [
        Anomalie(categorie, nom, nb=nb, total=total)
        for (categorie, nom), nb in sorted(compteurs.items())
    ]
