#!/usr/bin/env python3
"""Vérifie la configuration privacy du contexte Nao sans connexion DB."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TIER1_SOURCES = {
    "main.personne",
    "main.contact",
    "main.contact_structure_administrative",
    "min.utilisateur",
    "min.contact_membre_gouvernance",
    "min.membre",
    "min.personne_enrichie",
}

LLM_VIEWS = {
    "llm.personne",
    "llm.contact",
    "llm.structure_administrative",
    "llm.utilisateur",
    "llm.structure",
    "llm.membre",
    "llm.personne_enrichie",
}

NO_REPLACEMENT = {
    "main.structure",
    "min.contact_membre_gouvernance",
    "main.lieu_inclusion",
    "main.adresse",
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

TIER3_LLM_SOURCES = {
    "main.structure_administrative",
    "min.structure",
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

    for table in TIER1_SOURCES | TIER2 | TIER3_LLM_SOURCES | NO_REPLACEMENT:
        if table not in excludes:
            errors.append(f"nao_config.yaml: {table} manquant dans exclude")

    for template in FORBIDDEN_TEMPLATES:
        if re.search(rf"^\s*-\s*{template}\s*$", config, re.MULTILINE):
            errors.append(f"nao_config.yaml: template '{template}' interdit pour la privacy")

    if "postgres-inclusion-numerique" not in config:
        errors.append("nao_config.yaml: connexion postgres-inclusion-numerique absente")

    if "llm.*" not in config:
        errors.append("nao_config.yaml: llm.* manquant dans include")

    if "analytics" in config:
        errors.append("nao_config.yaml: référence au schéma analytics interdite")

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
    for table in sorted(TIER1_SOURCES | TIER2):
        schema, name = table.split(".", 1)
        if name not in privacy_text or schema not in privacy_text:
            errors.append(f"privacy.md: {table} non documenté")

    for view in sorted(LLM_VIEWS):
        if view not in privacy_text:
            errors.append(f"privacy.md: {view} non documenté")

    if "refuser" not in privacy_text.lower():
        errors.append("privacy.md: consigne de refus absente")

    if "database/sql" in privacy_text:
        errors.append("privacy.md: référence obsolète à database/sql")

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
    errors.extend(check_repos_config())
    errors.extend(check_rules_files())
    warnings = check_generated_context()

    print("=== Vérification privacy Nao ===\n")

    if errors:
        print("ERREURS:")
        for err in errors:
            print(f"  ✗ {err}")
    else:
        print("  ✓ nao_config.yaml et RULES.md OK")

    if warnings:
        print("\nAVERTISSEMENTS:")
        for warn in warnings:
            print(f"  ! {warn}")

    expected = TIER1_SOURCES | TIER2 | TIER3_LLM_SOURCES | NO_REPLACEMENT
    print(f"\nTables exclues: {len(excludes)}")
    print(f"Tier 1+2+3 attendus: {len(expected)}")
    print(f"Vues llm.* documentées: {len(LLM_VIEWS)}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
