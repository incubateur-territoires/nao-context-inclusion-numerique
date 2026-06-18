# nao-context-inclusion-numerique

Contexte pour l'instance Nao de l'inclusion numérique, sans exposition de données personnelles.

Ce dépôt ne modifie pas la base Postgres : il se connecte en lecture seule (rôle `nao_ro`) et synchronise le contexte agent.

## Déploiement

1. Copier [`.env.example`](.env.example) vers `.env` et renseigner les credentials `nao_ro`
2. Synchroniser le contexte : `nao sync`

## Protection RGPD (2 couches)

| Couche | Fichier |
|--------|---------|
| Exclusion contexte Nao | `nao_config.yaml` |
| Règles agent | `RULES.md`, `agent/semantics/privacy.md` |

Les vues `llm.*` et les droits du rôle `nao_ro` sont gérés dans les migrations de la base (hors de ce dépôt).

## Sources de contexte

| Source | Description |
|--------|-------------|
| Postgres (rôle `nao_ro`) | Schémas `admin`, `reference`, `llm`, tables Tier 4 |
| [Scripts ETL Airflow](https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts) | Pipeline extract / transform / load vers `main.*` |
| [Mon inclusion numérique](https://github.com/anct-cnum/suite-gestionnaire-numerique) | Application gouvernance, schéma `min`, statistiques Coop |

## Vérification

```bash
python3 scripts/verify-privacy-config.py
nao sync
```
