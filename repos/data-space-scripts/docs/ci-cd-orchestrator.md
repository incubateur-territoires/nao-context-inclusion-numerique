# CI/CD Orchestrator - Validation des imports ETL

## Vue d'ensemble

Le fichier `ci-cd-dag.py` génère dynamiquement **5 DAGs CI/CD** via une factory :

- **4 DAGs schedulés** (`ci-cd-carto-dag-import`, `ci-cd-aidants-connect-import`, `ci-cd-coop-import`, `ci-cd-schema-idPoste`) qui remplacent les schedules des DAGs feuilles. Chaque exécution passe par la validation CI/CD (restore, snapshots, évaluation, verdict) avant de déployer en prod.
- **1 DAG manuel** (`ci-cd-orchestrator`) qui permet de sélectionner le DAG cible via un paramètre enum.

Les DAGs feuilles (`coop-import`, `carto-dag-import`, `aidants-connect-import`, `schema-idPoste`) n'ont plus de schedule propre (`schedule=None`) et sont uniquement déclenchés par les DAGs CI/CD.

## DAGs générés

| DAG ID | Schedule | Cible | `auto_deploy_prod` par défaut |
|--------|----------|-------|-------------------------------|
| `ci-cd-carto-dag-import` | `0 1 * * *` | `carto-dag-import` | `true` |
| `ci-cd-aidants-connect-import` | `0 5 * * *` | `aidants-connect-import` | `true` |
| `ci-cd-coop-import` | `0 8 * * *` | `coop-import` | `true` |
| `ci-cd-schema-idPoste` | `timedelta(weeks=2)` | `schema-idPoste` | `true` |
| `ci-cd-orchestrator` | None (manuel) | sélectionnable | `false` |

## Architecture (par DAG)

```
restore_backup
    -> snapshot_avant (comptage + personnes + validation)
        -> trigger_dag_cible (DAG d'import sur dataspace_test)
            -> snapshot_apres
                -> evaluer (3 rapports comparés)
                    -> decide_deploy_prod (ShortCircuitOperator)
                        -> trigger_dag_prod (DAG cible sur sonum-prod-db)
                    -> notifier_mattermost (trigger_rule=all_done, attend evaluer + trigger_dag_prod)
```

`decide_deploy_prod` laisse passer uniquement si `auto_deploy_prod=True` ET verdict `OK`.
Sinon, `trigger_dag_prod` est skippé et `notifier_mattermost` se déclenche quand même (`all_done`).

## Paramètres du DAG

| Param | Type | Défaut | Description |
|-------|------|--------|-------------|
| `dag_cible` | string (ou enum pour le DAG manuel) | dépend du DAG | DAG à tester |
| `seuil_tolerance` | number | `3.0` | % max de diminution autorisée par table/métrique |
| `db_conn_id` | enum | `sonum-test-db` | Connexion Airflow vers la base de test |
| `auto_deploy_prod` | boolean | `true` (schedulés) / `false` (manuel) | Si activé, déclenche automatiquement le DAG cible sur `sonum-prod-db` après un verdict OK |

## Restore backup (`scripts/scw_restore_backup.sh`)

Le script fonctionne en **deux modes**, détectés automatiquement :

### Mode LOCAL (Docker Compose dev)

Détecté par la présence de `/opt/airflow/data/backups/`.

- Prend le fichier `.custom` le plus récent dans le répertoire
- `DROP DATABASE` + `CREATE DATABASE` + `pg_restore` dans le container `postgres-dataspace`
- Pas de dépendance externe

Pour tester en local, placer un dump `.custom` dans `data-airflow/backups/`.

### Mode REMOTE (Scaleway RDB prod)

Détecté par l'absence du répertoire backups local.

1. Recherche le backup Scaleway le plus récent (statut `ready`)
2. Supprime `dataspace_test` existante
3. Restaure le backup via `scw rdb backup restore`
4. Polling toutes les 30s jusqu'à complétion (timeout 30 min)
5. Attribue les permissions (`all`) aux utilisateurs listés dans la variable d'environnement `GRANT_USERS`

Garde-fou : refuse de restaurer sur `dataspace_prod`, `dataspace_dev` ou `postgres`.

#### Variables d'environnement (mode remote)

| Variable | Description |
|----------|-------------|
| `SCW_ACCESS_KEY` | Clé d'accès Scaleway |
| `SCW_SECRET_KEY` | Clé secrète Scaleway |
| `SCW_DEFAULT_PROJECT_ID` | ID du projet Scaleway (console -> Project Settings) |
| `SCW_RDB_INSTANCE_ID` | UUID de l'instance RDB |
| `SCW_RESTORE_DB_NAME` | Base cible (défaut: `dataspace_test`) |
| `SCW_POLL_INTERVAL` | Intervalle polling en secondes (défaut: `30`) |
| `SCW_POLL_TIMEOUT` | Timeout total en secondes (défaut: `1800`) |
| `GRANT_USERS` | Liste d'utilisateurs DB séparés par des espaces (permissions `all` après restore) |

#### Test manuel (sans Airflow)

```bash
export SCW_ACCESS_KEY=...
export SCW_SECRET_KEY=...
export SCW_DEFAULT_PROJECT_ID=...
export SCW_RDB_INSTANCE_ID=...
export SCW_RESTORE_DB_NAME=dataspace_test
bash scripts/scw_restore_backup.sh
```

## Rapports d'évaluation

Trois rapports sont collectés avant et après l'exécution du DAG cible :

### 1. Comptage (`scripts/rapport_comptage.py`)

Compare le nombre de lignes dans les tables principales (`main.personne`, `main.structure`, etc.).

### 2. Personnes (`scripts/rapport_personnes.py`)

Statistiques détaillées sur la vue `min.personne_enrichie` (types, statuts, labellisations, emploi).

**Catégories informatives** (non bloquantes) : `API get_mediateur (CN)` — un écart sur ces métriques affiche `INFO` mais ne produit pas de verdict NOK.

### 3. Validation (`scripts/rapport_validation.py`)

Validation de données de référence (structure Allier, statistiques financières, états postes, contrats).

## Règles de verdict

| Situation | Verdict |
|-----------|---------|
| Augmentation (ecart >= 0) | OK |
| Perte totale (avant > 0, apres == 0) | NOK |
| Diminution dans le seuil (abs(%) <= seuil) | OK |
| Diminution hors seuil | NOK |
| Catégorie informative avec écart | INFO (non bloquant) |

**Verdict global** = NOK si au moins une métrique bloquante est NOK dans l'un des 3 rapports.

## Configuration Airflow requise

### Variables Airflow

| Variable | Valeur | Usage |
|----------|--------|-------|
| `SCW_RDB_INSTANCE_ID` | UUID Scaleway | Restore backup |
| `SCW_ACCESS_KEY` | Clé Scaleway | Restore backup |
| `SCW_SECRET_KEY` | Secret Scaleway | Restore backup |
| `SCW_DEFAULT_PROJECT_ID` | Projet Scaleway | Restore backup |
| `SCW_DEFAULT_ORGANIZATION_ID` | Organisation Scaleway | Restore backup |
| `MATTERMOST_WEBHOOK_URI` | URL webhook | Notifications |
| `MATTERMOST_NOTIFICATION_CHANNEL` | Channel | Notifications |

### Connexion Airflow

`sonum-test-db` doit pointer vers `dataspace_test`.

## Gestion d'erreurs

| Point de défaillance | Comportement |
|---------------------|--------------|
| Restore échoue | DAG échoue -> callback Mattermost |
| Snapshot échoue | DAG échoue -> callback Mattermost |
| DAG cible échoue | Tâches suivantes skippées, sauf `notifier_mattermost` (all_done) |
| Verdict NOK | DAG **réussit**, message Mattermost affiche NOK, deploy prod skippé |
| Verdict OK + `auto_deploy_prod=false` | Deploy prod skippé, notification envoyée |
| Verdict OK + `auto_deploy_prod=true` | DAG cible lancé sur `sonum-prod-db`, notification après complétion |

## Usage CLI standalone

Les rapports peuvent aussi être utilisés en ligne de commande :

```bash
# Snapshot
DATABASE_URL=... python scripts/rapport_comptage.py --snapshot -o avant.json

# Évaluation avec seuil
DATABASE_URL=... python scripts/rapport_comptage.py --evaluer avant.json --seuil 3.0
```
