#!/usr/bin/env python3
"""Vérifie la configuration privacy du contexte Nao sans connexion DB."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TIER1 = {
    "main.personne",
    "main.contact",
    "main.contact_structure_administrative",
    "min.utilisateur",
    "min.contact_membre_gouvernance",
    "min.membre",
    "min.personne_enrichie",
}

TIER2 = {
    "main.personne_affectations",
    "main.personne_affectations_emploi",
    "main.personne_affectations_lieu",
    "main.formation",
    "main.contrat",
    "main.coordination_mediation",
    "main.poste",
    "main.activites_coop",
    "min.postes_conseiller_numerique_synthese",
    "min.beneficiaire_subvention",
    "min.co_financement",
    "min.porteur_action",
    "min.demande_de_subvention",
    "min.action",
    "min.comite",
    "min.feuille_de_route",
    "min.gouvernance",
}

TIER3_SOURCES = {
    "main.structure",
    "main.structure_administrative",
    "main.lieu_inclusion",
    "main.adresse",
    "min.structure",
}

FORBIDDEN_SELECT_COLUMNS = {
    "contact",
    "prenom",
    "email",
    "telephone",
    "email_de_contact",
    "sso_email",
    "sso_id",
    "geom",
    "numero_voie",
    "nom_voie",
    "adresse",
    "personne_id",
    "observations",
    "note_privee",
    "piece_jointe",
}

FORBIDDEN_TEMPLATES = {"preview", "profiling", "ai_summary"}


def load_excludes() -> set[str]:
    config = (ROOT / "nao_config.yaml").read_text()
    excludes: set[str] = set()
    in_exclude = False
    for line in config.splitlines():
        stripped = line.strip()
        if stripped.startswith("exclude:"):
            in_exclude = True
            continue
        if in_exclude:
            if stripped.startswith("- "):
                excludes.add(stripped[2:].strip())
            elif stripped and not stripped.startswith("#") and not line.startswith(" "):
                in_exclude = False
    return excludes


def check_nao_config(excludes: set[str]) -> list[str]:
    errors: list[str] = []
    config = (ROOT / "nao_config.yaml").read_text()

    for table in TIER1 | TIER2 | TIER3_SOURCES:
        if table not in excludes:
            errors.append(f"nao_config.yaml: {table} manquant dans exclude")

    for template in FORBIDDEN_TEMPLATES:
        if re.search(rf"^\s*-\s*{template}\s*$", config, re.MULTILINE):
            errors.append(f"nao_config.yaml: template '{template}' interdit pour la privacy")

    if "postgres-inclusion-numerique" not in config:
        errors.append("nao_config.yaml: connexion postgres-inclusion-numerique absente")

    if "analytics.*" not in config:
        errors.append("nao_config.yaml: analytics.* manquant dans include")

    return errors


def extract_select_columns(view_body: str) -> set[str]:
    select_part = view_body.split("FROM", 1)[0]
    columns: set[str] = set()
    for line in select_part.splitlines():
        line = line.strip().rstrip(",")
        if not line or line.startswith("--") or line.upper().startswith("SELECT"):
            continue
        if line.upper().startswith("CASE") or line.upper().startswith("COUNT("):
            continue
        token = line.split()[0].strip(",")
        if token.endswith(")"):
            continue
        columns.add(token.lower())
    return columns


def check_analytics_views() -> list[str]:
    errors: list[str] = []
    sql = (ROOT / "database/sql/01_analytics_views.sql").read_text()

    view_blocks = re.split(r"CREATE OR REPLACE VIEW analytics\.(\w+)", sql)
    for i in range(1, len(view_blocks), 2):
        view_name = view_blocks[i]
        body = view_blocks[i + 1].split("COMMENT ON VIEW")[0]
        selected = extract_select_columns(body)
        leaked = selected & FORBIDDEN_SELECT_COLUMNS
        if leaked:
            errors.append(
                f"01_analytics_views.sql: colonnes interdites dans analytics.{view_name}: {sorted(leaked)}"
            )

    return errors


def check_repos_config() -> list[str]:
    errors: list[str] = []
    config = (ROOT / "nao_config.yaml").read_text()

    if "data-space-scripts" not in config:
        errors.append("nao_config.yaml: repo data-space-scripts manquant")

    if "gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts" not in config:
        errors.append("nao_config.yaml: URL GitLab scripts absente")

    if "suite-gestionnaire-numerique" not in config:
        errors.append("nao_config.yaml: repo suite-gestionnaire-numerique manquant")

    if "github.com/anct-cnum/suite-gestionnaire-numerique" not in config:
        errors.append("nao_config.yaml: URL GitHub MIN absente")

    semantics = ROOT / "agent/semantics/dataspace-etl.md"
    if not semantics.exists():
        errors.append("agent/semantics/dataspace-etl.md manquant")

    min_semantics = ROOT / "agent/semantics/mon-inclusion-numerique.md"
    if not min_semantics.exists():
        errors.append("agent/semantics/mon-inclusion-numerique.md manquant")

    return errors


def check_rules_files() -> list[str]:
    errors: list[str] = []
    rules = ROOT / "RULES.md"
    privacy = ROOT / "agent/semantics/privacy.md"

    if not rules.read_text().strip():
        errors.append("RULES.md est vide")
    if "RGPD" not in rules.read_text() and "Privacy" not in rules.read_text():
        errors.append("RULES.md: section privacy absente")

    if "dataspace-etl.md" not in rules.read_text():
        errors.append("RULES.md: référence dataspace-etl.md absente")

    if "mon-inclusion-numerique.md" not in rules.read_text():
        errors.append("RULES.md: référence mon-inclusion-numerique.md absente")

    privacy_text = privacy.read_text()
    for table in sorted(TIER1 | TIER2):
        schema, name = table.split(".", 1)
        if name not in privacy_text or schema not in privacy_text:
            errors.append(f"privacy.md: {table} non documenté")

    if "refuser" not in privacy_text.lower():
        errors.append("privacy.md: consigne de refus absente")

    return errors


def check_generated_context() -> list[str]:
    warnings: list[str] = []
    databases_dir = ROOT / "databases"
    if not databases_dir.exists():
        warnings.append(
            "databases/: dossier absent — lancer 'nao sync' après configuration de .env"
        )
        return warnings

    for md_file in databases_dir.rglob("*.md"):
        content = md_file.read_text(errors="ignore").lower()
        if any(
            needle in content
            for needle in ("@example.com", "prenom", "sso_email", "telephone")
        ):
            warnings.append(f"Fichier sync potentiellement sensible: {md_file.relative_to(ROOT)}")

    return warnings


def main() -> int:
    excludes = load_excludes()
    errors: list[str] = []
    errors.extend(check_nao_config(excludes))
    errors.extend(check_analytics_views())
    errors.extend(check_repos_config())
    errors.extend(check_rules_files())
    warnings = check_generated_context()

    print("=== Vérification privacy Nao ===\n")

    if errors:
        print("ERREURS:")
        for err in errors:
            print(f"  ✗ {err}")
    else:
        print("  ✓ nao_config.yaml, vues analytics et RULES.md OK")

    if warnings:
        print("\nAVERTISSEMENTS:")
        for warn in warnings:
            print(f"  ! {warn}")

    print(f"\nTables exclues: {len(excludes)}")
    print(f"Tier 1+2+3 attendus: {len(TIER1 | TIER2 | TIER3_SOURCES)}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
