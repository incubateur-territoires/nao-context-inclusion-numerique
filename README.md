# nao-context-inclusion-numerique

Contexte pour l'instance Nao de l'inclusion numérique, sans exposition de données personnelles.

## Déploiement

1. Exécuter les scripts SQL sur la base Postgres :
   - [`database/sql/01_analytics_views.sql`](database/sql/01_analytics_views.sql)
   - [`database/sql/02_nao_readonly_role.sql`](database/sql/02_nao_readonly_role.sql) (modifier le mot de passe)
2. Copier [`.env.example`](.env.example) vers `.env` et renseigner les credentials
3. Synchroniser le contexte : `nao sync`

## Protection RGPD (3 couches)

| Couche | Fichier |
|--------|---------|
| Rôle Postgres restreint | `database/sql/02_nao_readonly_role.sql` |
| Exclusion contexte Nao | `nao_config.yaml` |
| Règles agent | `RULES.md`, `agent/semantics/privacy.md` |

## Sources de contexte

| Source | Description |
|--------|-------------|
| Postgres (rôle `nao_readonly`) | Schémas `admin`, `reference`, `analytics`, tables Tier 4 |
| [Scripts ETL Airflow](https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts) | Pipeline extract / transform / load vers `main.*` |
| [Mon inclusion numérique](https://github.com/anct-cnum/suite-gestionnaire-numerique) | Application gouvernance, schéma `min`, statistiques Coop |

## Décisions

- [Tier 3 — vues analytics](database/decisions/tier3-analytics-views.md)

## Vérification

```bash
python3 scripts/verify-privacy-config.py
nao sync
```
