# nao-context-inclusion-numerique

Contexte de l'agent Nao pour l'inclusion numérique (ANCT / Société Numérique), sans
donnée nominative.

Ce dépôt ne modifie pas la base Postgres : l'agent s'y connecte en lecture seule avec
le rôle `nao_ro`, et ce dépôt décrit ce que ce rôle voit.

## Comment ça marche

| Couche | Où | Rôle |
|--------|----|------|
| Confidentialité | base Postgres (migrations Flyway du dépôt dataspace : V102, V103, V172, V173) | vues `llm.*` sans nominatif, accès révoqués : **seule** couche de protection |
| Périmètre | `nao_config.yaml` (`include`, `allow_listed_only`) | reflète exactement ce que `nao_ro` lit ; frontière dure à l'exécution |
| Schéma | `databases/` (généré par `nao sync`) | un `columns.md` par table : colonnes, types, description issue de `COMMENT ON` |
| Code source | `repos/` (généré par `nao sync`) | migrations, DAG et docs du dataspace ; docs et modèle Prisma de MIN |
| Comportement | `RULES.md`, `agent/semantics/*.md` | règles de support, modèle de données, périmètre, pipeline, application MIN |

L'agent apprend le schéma **uniquement** par `databases/` : sans sync, il devine les
colonnes. Le serveur Nao ne lance jamais `nao sync` lui-même, il ne fait que récupérer
ce dépôt (« Pull latest » dans Réglages → Git).

## Mettre à jour le contexte

1. Installer le CLI (une fois) :
   ```bash
   uv tool install --with 'ibis-framework[postgres]' --with packaging 'nao-core[postgres]'
   ```
2. Copier [`.env.example`](.env.example) vers `.env`, renseigner la connexion `nao_ro`
   (une copie de la base suffit : seul le schéma est lu), puis exporter les variables :
   ```bash
   set -a; . ./.env; set +a
   nao debug        # doit afficher ✓ sur postgres-inclusion-numerique
   nao sync         # régénère databases/ et repos/
   python3 scripts/verify-privacy-config.py
   ```
3. Commiter `databases/`, `repos/`, `.meta/` et la config, pousser, puis « Pull latest »
   côté Nao.

À refaire après toute migration qui touche `llm.*`, un `GRANT`/`REVOKE` sur `nao_ro`
ou l'ajout d'une table dans `include`.

## Ouvrir ou fermer une table

1. Migration Flyway côté dataspace (vue `llm.*` ou `GRANT`/`REVOKE` sur `nao_ro`,
   test de non-régression dans `tests/test_llm_sans_pii.py`).
2. Reporter la table dans `include` de `nao_config.yaml`.
3. `nao sync`, vérification, commit, « Pull latest ».

## Liens

- Pipeline : [scripts (GitLab)](https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts)
- Application : [Mon inclusion numérique (GitHub)](https://github.com/anct-cnum/suite-gestionnaire-numerique)
- Documentation Nao : https://docs.getnao.io/
