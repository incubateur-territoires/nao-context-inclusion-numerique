# Décision Tier 3 — Vues analytics (option B)

**Date :** 2026-06-15  
**Statut :** Retenu

## Contexte

Les tables Tier 3 (`main.structure`, `main.structure_administrative`, `main.lieu_inclusion`, `main.adresse`, `min.structure`) contiennent des données utiles à l'analytics territorial et structurel, mais aussi des colonnes sensibles (contact JSONB, adresses précises, référents nommés).

## Options évaluées

| Option | Description | Impact analytics |
|--------|-------------|------------------|
| **A — Exclusion totale** | Ne pas exposer ces tables à Nao | Perte des analyses sur lieux, structures et géolocalisation |
| **B — Vues anonymisées** | Exposer uniquement des vues `analytics.*` sans PII | Conserve les KPI structurels/territoriaux sans contact ni adresse nominative |

## Décision

**Option B retenue.** Les tables sources Tier 3 restent exclues du contexte Nao et du rôle `nao_readonly`. Seules les vues du schéma `analytics` sont exposées.

## Colonnes exclues des vues

- `contact` (jsonb)
- `edited_by`, `deleted_by`
- Adresse précise : `numero_voie`, `nom_voie`, `repetition`, `geom`, `clef_interop`, `code_ban`
- `import_warnings` (peut contenir des données sources brutes)
- `adresse` texte et `contact` sur `min.structure`

## Implémentation

Voir [`database/sql/01_analytics_views.sql`](../sql/01_analytics_views.sql) et [`database/sql/02_nao_readonly_role.sql`](../sql/02_nao_readonly_role.sql).
