#!/usr/bin/env python3
"""Vérifie la cohérence du contexte Nao avec le périmètre du rôle nao_ro.

Sans connexion : contrôle nao_config.yaml (tables interdites absentes de
`include`, garde-fous activés, pas de template qui versionne des données),
la présence du schéma synchronisé et la documentation de chaque vue llm.*.

Avec NAO_DB_* exportées (ou DATABASE_URL) : compare en plus `include` avec ce
que nao_ro peut réellement lire, dans les deux sens.
"""

from __future__ import annotations

import fnmatch
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Tables sources remplacées par une vue llm.* ou sans remplaçant : ne doivent
# jamais entrer dans le contexte, même si un grant réapparaissait en base.
INTERDITES = {
    "main.personne",
    "main.contact",
    "main.structure",
    "main.structure_administrative",
    "main.lieu_inclusion",
    "main.lieu_appariement",
    "main.adresse",
    "main.activites_coop",
    "min.utilisateur",
    "min.membre",
    "min.structure",
    "min.personne_enrichie",
    "min.contact_membre_gouvernance",
    "min.gouvernance",
    "min._prisma_migrations",
}

SCHEMAS_INTERDITS = {"source", "staging", "audit", "coop", "import", "api", "dataviz", "auth"}

# Templates qui versionneraient des lignes ou des statistiques de données.
TEMPLATES_INTERDITS = {"preview", "profiling", "ai_summary", "query_history"}


def lire_config() -> tuple[str, list[str], list[str], list[str]]:
    texte = (ROOT / "nao_config.yaml").read_text()
    bloc = texte.split("repos:")[0]

    def liste(cle: str) -> list[str]:
        m = re.search(rf"^\s*{cle}:\n((?:\s*(?:#.*|- .*)\n)+)", bloc, re.MULTILINE)
        if not m:
            return []
        return [
            ligne.strip()[2:].strip()
            for ligne in m.group(1).splitlines()
            if ligne.strip().startswith("- ")
        ]

    return texte, liste("include"), liste("exclude"), liste("templates")


def correspond(table: str, motifs: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(table, motif) for motif in motifs)


def check_config(texte: str, include: list[str], exclude: list[str], templates: list[str]) -> list[str]:
    erreurs: list[str] = []
    if not include:
        erreurs.append("nao_config.yaml : include vide")
    for table in sorted(INTERDITES):
        if correspond(table, include) and not correspond(table, exclude):
            erreurs.append(f"nao_config.yaml : {table} entre dans le contexte")
    for motif in include:
        schema = motif.split(".", 1)[0]
        if schema in SCHEMAS_INTERDITS:
            erreurs.append(f"nao_config.yaml : schéma {schema} interdit ({motif})")
    if not re.search(r"^\s*allow_listed_only:\s*true", texte, re.MULTILINE):
        erreurs.append("nao_config.yaml : allow_listed_only doit valoir true")
    for t in templates:
        if t in TEMPLATES_INTERDITS:
            erreurs.append(f"nao_config.yaml : template '{t}' versionnerait des données")
    if "columns" not in templates:
        erreurs.append("nao_config.yaml : template 'columns' requis")
    for cle in ("NAO_DB_HOST", "NAO_DB_PORT", "NAO_DB_NAME", "NAO_DB_USER", "NAO_DB_PASSWORD"):
        if cle not in texte:
            erreurs.append(f"nao_config.yaml : variable {cle} non référencée")
    return erreurs


def tables_synchronisees() -> set[str]:
    tables: set[str] = set()
    for chemin in (ROOT / "databases").rglob("columns.md"):
        parties = {p.split("=", 1)[0]: p.split("=", 1)[1] for p in chemin.parts if "=" in p}
        if "schema" in parties and "table" in parties:
            tables.add(f"{parties['schema']}.{parties['table']}")
    return tables


def check_sync(include: list[str], exclude: list[str]) -> list[str]:
    erreurs: list[str] = []
    tables = tables_synchronisees()
    if not tables:
        erreurs.append("databases/ : aucun columns.md — lancer 'nao sync'")
        return erreurs
    for table in sorted(tables):
        if table.split(".")[0] in SCHEMAS_INTERDITS or table in INTERDITES:
            erreurs.append(f"databases/ : {table} synchronisée alors qu'interdite")
        if not correspond(table, include) or correspond(table, exclude):
            erreurs.append(f"databases/ : {table} synchronisée mais hors include")
    for chemin in (ROOT / "databases").rglob("*.md"):
        contenu = chemin.read_text(errors="ignore")
        if re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", contenu):
            erreurs.append(f"databases/ : adresse mail dans {chemin.relative_to(ROOT)}")
    for chemin in ROOT.glob("*.sql"):
        erreurs.append(f"{chemin.name} : dump de schéma versionné à la main — supprimer, 'nao sync' fait foi")
    return erreurs


def check_docs() -> list[str]:
    erreurs: list[str] = []
    rules = (ROOT / "RULES.md").read_text()
    privacy = (ROOT / "agent/semantics/privacy.md").read_text()
    for fichier in ("modele-donnees.md", "privacy.md", "dataspace-etl.md", "mon-inclusion-numerique.md"):
        if not (ROOT / "agent/semantics" / fichier).exists():
            erreurs.append(f"agent/semantics/{fichier} manquant")
        elif fichier not in rules:
            erreurs.append(f"RULES.md : {fichier} non référencé")
    for table in sorted(tables_synchronisees()):
        if table.startswith("llm.") and f"`{table}`" not in privacy:
            erreurs.append(f"privacy.md : {table} non documentée")
    for mot in ("Tier 1", "Tier 2", "Refuser toute"):
        if mot in rules or mot in privacy:
            erreurs.append(f"vocabulaire obsolète « {mot} » dans RULES.md / privacy.md")
    return erreurs


def check_base(include: list[str], exclude: list[str]) -> list[str]:
    """Compare include ↔ privilèges réels de nao_ro. Ignoré sans connexion."""
    url = os.environ.get("DATABASE_URL")
    if not url and os.environ.get("NAO_DB_HOST"):
        e = os.environ
        url = (
            f"postgresql://{e['NAO_DB_USER']}:{e['NAO_DB_PASSWORD']}@{e['NAO_DB_HOST']}"
            f":{e.get('NAO_DB_PORT', '5432')}/{e['NAO_DB_NAME']}"
        )
    if not url:
        return ["(base) connexion absente : export NAO_DB_* ou DATABASE_URL pour comparer include ↔ grants"]
    try:
        import psycopg  # type: ignore
    except ImportError:
        try:
            import psycopg2 as psycopg  # type: ignore
        except ImportError:
            return ["(base) psycopg indisponible : comparaison include ↔ grants sautée"]
    erreurs: list[str] = []
    with psycopg.connect(url) as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT table_schema || '.' || table_name FROM information_schema.table_privileges "
            "WHERE grantee = 'nao_ro' AND privilege_type = 'SELECT'"
        )
        lisibles = {r[0] for r in cur.fetchall()}
    for table in sorted(lisibles):
        if table in INTERDITES or table.split(".")[0] in SCHEMAS_INTERDITS:
            erreurs.append(f"base : nao_ro lit {table} (grant à révoquer)")
        elif not correspond(table, include) and not correspond(table, exclude):
            erreurs.append(f"base : nao_ro lit {table}, absente de include (à ajouter ou à révoquer)")
    for table in sorted(tables_synchronisees()):
        if table not in lisibles:
            erreurs.append(f"base : {table} synchronisée mais plus lisible par nao_ro")
    return erreurs


def main() -> int:
    texte, include, exclude, templates = lire_config()
    erreurs = check_config(texte, include, exclude, templates) + check_sync(include, exclude) + check_docs()
    avertissements = [e for e in check_base(include, exclude) if e.startswith("(")]
    erreurs += [e for e in check_base(include, exclude) if not e.startswith("(")]

    print("=== Vérification du contexte Nao ===\n")
    for e in erreurs:
        print(f"  ✗ {e}")
    for a in avertissements:
        print(f"  ! {a}")
    if not erreurs:
        print("  ✓ configuration, schéma synchronisé et documentation cohérents")
    print(f"\nTables synchronisées : {len(tables_synchronisees())}")
    print(f"Motifs include : {len(include)}, exclude : {len(exclude)}")
    return 1 if erreurs else 0


if __name__ == "__main__":
    sys.exit(main())
