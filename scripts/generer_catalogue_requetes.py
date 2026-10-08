#!/usr/bin/env python3
"""Génère agent/semantics/requetes-tableau-de-bord.md depuis tests/*.yml.

Source de vérité unique : chaque test porte la question métier et le SQL de
référence (validé contre la base avec le rôle nao_ro). Le catalogue donne à
l'agent la requête canonique à exécuter telle quelle, au lieu de la réinventer.
Relancer après toute modification des tests ; le fichier généré est commité.
"""

from __future__ import annotations

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "agent" / "semantics" / "requetes-tableau-de-bord.md"

BLOCS = {
    "a": "A — Points de vigilance des lieux", "b": "B — Données de la structure",
    "c": "C — État des lieux de l'inclusion numérique", "d": "D — Médiateurs et aidants",
    "e": "E — Gouvernances", "f": "F — Financements", "g": "G — Bénéficiaires de financements",
    "h": "H — Label Conseiller numérique", "i": "I — Page admin des gouvernances",
    "s": "S — Page Statistiques (médiation numérique)",
}


def main() -> None:
    tests = sorted(yaml.safe_load(p.read_text()) | {"_file": p.stem} for p in (ROOT / "tests").glob("tdb_*.yml")
                   ) if False else []
    for p in sorted((ROOT / "tests").glob("tdb_*.yml")):
        t = yaml.safe_load(p.read_text()); t["_file"] = p.stem; tests.append(t)
    # Reformulations (tests/variantes/<nom>__<variante>.yml) : listées sous la question
    # canonique pour qu'un grep sur une question courte ou tournée autrement tombe
    # sur la bonne requête.
    variantes: dict[str, list[str]] = {}
    for p in sorted((ROOT / "tests" / "variantes").glob("tdb_*__*.yml")):
        base = p.stem.split("__", 1)[0]
        variantes.setdefault(base, []).append(yaml.safe_load(p.read_text())["prompt"].strip())
    parts = [
        "# Requêtes canoniques du tableau de bord MIN\n",
        "> Fichier **généré** par `scripts/generer_catalogue_requetes.py` depuis `tests/*.yml` et `tests/variantes/` : ne pas éditer à la main.\n",
        "> Pour chaque indicateur : la question telle qu'un utilisateur la pose, et **la requête à exécuter telle quelle** "
        "(périmètre national). Pour un département ou une région, ajouter uniquement le filtre territorial "
        "(voir `tableau-de-bord-min.md`, « Mailles et périmètre ») sans toucher au reste. "
        "Les valeurs `kind: table` renvoient un libellé et un nombre ; `scalar` un seul nombre.\n",
    ]
    bloc_courant = None
    for t in tests:
        bloc = t["_file"].split("_")[1]
        if bloc != bloc_courant:
            parts.append(f"\n## {BLOCS.get(bloc, bloc.upper())}\n")
            bloc_courant = bloc
        autres = "".join(f"- {q}\n" for q in variantes.get(t["_file"], []) if q != t["prompt"].strip())
        autres = f"\n**Autres formulations** :\n{autres}" if autres else ""
        parts.append(f"\n### `{t['name']}` ({t.get('kind', 'scalar')})\n\n**Question** : {t['prompt'].strip()}\n{autres}\n```sql\n{t['sql'].rstrip()}\n```\n")
    OUT.write_text("".join(parts))
    print(f"{OUT.relative_to(ROOT)} : {len(tests)} requêtes")


if __name__ == "__main__":
    main()
