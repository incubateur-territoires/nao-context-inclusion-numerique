"""Parsing des fichiers de tests qualité SQL (fiche 03) — fonctions pures.

Les fichiers ``tests/quality/*.sql`` déclarent des invariants « 0 ligne
attendue » : un en-tête ``-- test: nom (severite)`` suivi de commentaires
descriptifs et d'une requête SQL. Ce module les découpe en tests exécutables ;
l'exécution (PostgresHook, logs) vit dans le shell ``etl/qualite_tests.py``.
"""

import re
from dataclasses import dataclass

_EN_TETE = re.compile(r"^--\s*test:\s*(?P<nom>[\w-]+)\s*\((?P<severite>\w+)\)")


@dataclass(frozen=True)
class InvariantQualite:
    """Un invariant SQL nommé ; la requête renvoie 0 ligne si tout va bien."""

    nom: str
    severite: str
    sql: str


def parser_tests(texte: str) -> list[InvariantQualite]:
    """Découpe un fichier de tests qualité en invariants exécutables.

    Les lignes avant le premier en-tête (prologue) et les lignes de
    commentaires sont ignorées ; un en-tête sans requête est écarté.
    """
    tests: list[InvariantQualite] = []
    nom: str | None = None
    severite = ""
    lignes: list[str] = []

    def finaliser() -> None:
        if nom is not None and lignes:
            tests.append(
                InvariantQualite(nom=nom, severite=severite, sql="\n".join(lignes))
            )

    for ligne in texte.splitlines():
        entete = _EN_TETE.match(ligne.strip())
        if entete:
            finaliser()
            nom = entete["nom"]
            severite = entete["severite"]
            lignes = []
            continue
        contenu = ligne.rstrip()
        if nom is None or not contenu or contenu.lstrip().startswith("--"):
            continue
        lignes.append(contenu)
    finaliser()
    return tests
