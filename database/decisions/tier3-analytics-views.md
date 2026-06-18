# Décision Tier 3 — Vues analytics (complément llm.*)

**Date :** 2026-06-15  
**Statut :** Retenu (mis à jour)

## Contexte

Les tables Tier 3 contiennent des données utiles à l'analytics territorial et structurel, mais aussi des colonnes sensibles (contact JSONB, adresses précises, référents nommés).

Depuis juin 2026, les entités personne et structure passent par le schéma **`llm.*`** (voir [`database/sql/00_llm_views.sql`](../sql/00_llm_views.sql)). Le schéma **`analytics.*`** reste pour les lieux, adresses communales et KPI agrégés.

## Répartition des responsabilités

| Besoin | Schéma | Exemples |
|--------|--------|----------|
| Entités sans PII (même grain) | `llm.*` | `llm.personne`, `llm.structure_administrative`, `llm.utilisateur` |
| Lieux et adresses | `analytics.*` | `analytics.lieu_inclusion_publique`, `analytics.adresse_publique` |
| Comptages agrégés | `analytics.*` | `analytics.mediateurs_par_structure`, `analytics.postes_synthese` |

## Tables sans remplaçant

- `main.structure` — legacy en voie de disparition, accès coupé
- `min.contact_membre_gouvernance` — 100 % PII, vue supprimée en V103

## Colonnes exclues des vues analytics

- `contact` (jsonb)
- `edited_by`, `deleted_by`
- Adresse précise : `numero_voie`, `nom_voie`, `repetition`, `geom`, `clef_interop`, `code_ban`
- `import_warnings` (peut contenir des données sources brutes)

## Implémentation

1. [`database/sql/00_llm_views.sql`](../sql/00_llm_views.sql)
2. [`database/sql/01_analytics_views.sql`](../sql/01_analytics_views.sql)
3. [`database/sql/02_nao_readonly_role.sql`](../sql/02_nao_readonly_role.sql) — rôle `nao_ro`
