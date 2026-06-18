# nao-context-inclusion-numerique

Contexte pour l'instance Nao de l'inclusion numérique, sans exposition de données personnelles.

## Déploiement

1. Exécuter les scripts SQL sur la base Postgres (dans l'ordre) :
   - [`database/sql/00_llm_views.sql`](database/sql/00_llm_views.sql)
   - [`database/sql/01_analytics_views.sql`](database/sql/01_analytics_views.sql)
   - [`database/sql/02_nao_readonly_role.sql`](database/sql/02_nao_readonly_role.sql) (modifier le mot de passe)
2. Copier [`.env.example`](.env.example) vers `.env` et renseigner les credentials (`nao_ro`)
3. Synchroniser le contexte : `nao sync`

## Protection RGPD (3 couches)

| Couche | Fichier |
|--------|---------|
| Rôle Postgres restreint (`nao_ro`) | `database/sql/02_nao_readonly_role.sql` |
| Vues sans PII (`llm.*`, `analytics.*`) | `database/sql/00_llm_views.sql`, `database/sql/01_analytics_views.sql` |
| Exclusion contexte Nao | `nao_config.yaml` |
| Règles agent | `RULES.md`, `agent/semantics/privacy.md` |

## Sources de contexte

| Source | Description |
|--------|-------------|
| Postgres (rôle `nao_ro`) | Schémas `admin`, `reference`, `llm`, `analytics`, tables Tier 4 |
| [Scripts ETL Airflow](https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts) | Pipeline extract / transform / load vers `main.*` |
| [Mon inclusion numérique](https://github.com/anct-cnum/suite-gestionnaire-numerique) | Application gouvernance, schéma `min`, statistiques Coop |

## Décisions

- [Tier 3 — vues analytics](database/decisions/tier3-analytics-views.md)

## Vérification

```bash
python3 scripts/verify-privacy-config.py
nao sync
```
