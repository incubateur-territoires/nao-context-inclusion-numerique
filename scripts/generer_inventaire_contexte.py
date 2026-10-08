#!/usr/bin/env python3
"""Régénère l'inventaire des tables du contexte dans RULES.md depuis databases/.

L'agent invente des chemins (`schema=min/table=subvention`, `table/gouvernance`…)
quand il ne connaît pas la liste exacte des tables synchronisées ; Nao répond alors
« Access denied » (le contrôle d'accès passe avant la recherche du fichier) et le tour
part en vrille. L'inventaire, injecté dans RULES.md entre deux balises, lui donne la
liste fermée. Relancer après chaque `nao sync` ; le résultat est commité.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULES = ROOT / "RULES.md"
DEBUT, FIN = "<!-- inventaire:debut -->", "<!-- inventaire:fin -->"


def main() -> None:
    bases = sorted((ROOT / "databases").glob("type=*/database=*"))
    lignes = []
    for base in bases:
        chemin = base.relative_to(ROOT).as_posix()
        lignes.append(f"Chemin d'un fichier de table : `{chemin}/schema=<schema>/table=<table>/columns.md` "
                      "(signe `=` après `schema` et `table`, jamais `/`).\n")
        lignes.append("| Schéma | Tables synchronisées (liste fermée) |\n|--------|------|\n")
        for schema in sorted(base.glob("schema=*")):
            tables = sorted(p.name.split("=", 1)[1] for p in schema.glob("table=*"))
            lignes.append(f"| `{schema.name.split('=', 1)[1]}` | {', '.join(f'`{t}`' for t in tables)} |\n")
    bloc = f"{DEBUT}\n{''.join(lignes)}{FIN}"
    texte = RULES.read_text()
    motif = re.compile(re.escape(DEBUT) + ".*?" + re.escape(FIN), re.S)
    if not motif.search(texte):
        raise SystemExit(f"balises {DEBUT} / {FIN} absentes de RULES.md")
    RULES.write_text(motif.sub(lambda _: bloc, texte))
    n = sum(1 for _ in (ROOT / "databases").glob("type=*/database=*/schema=*/table=*"))
    print(f"RULES.md : inventaire de {n} tables")


if __name__ == "__main__":
    main()
