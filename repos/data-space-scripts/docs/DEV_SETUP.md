# Guide de Déploiement Local

Ce guide explique comment déployer la stack Airflow/ETL + PostgREST en environnement de développement local.

## Sommaire

- [Connexion PostgreSQL Métier](#connexion-postgresql-métier-data-etl)
- [Versions](#versions)
- [Prérequis](#prérequis)
- [Architecture](#architecture)
- [Installation](#installation)
- [Installation Pas à Pas](#installation-pas-à-pas)
- [Services](#services)
- [Commandes Utiles](#commandes-utiles)
- [PostgREST - API REST](#postgrest---api-rest)
- [Connexion à PostgreSQL](#connexion-à-postgresql)
- [Flyway - Migrations de la Base de Données](#flyway---migrations-de-la-base-de-données)
  - [Créer une nouvelle migration](#créer-une-nouvelle-migration)
  - [Commandes Flyway](#commandes-flyway)
  - [Résolution de problèmes Flyway](#résolution-de-problèmes-flyway)
- [Configuration des Connexions Airflow](#configuration-des-connexions-airflow)
- [Troubleshooting](#troubleshooting)
- [Structure des Fichiers](#structure-des-fichiers)
- [Notes sur Airflow 3.x](#notes-sur-airflow-3x)

---

## Connexion PostgreSQL Métier (Data ETL)

```
Host:     localhost
Port:     5532
Database: dataspace_dev
User:     dataspace
Password: dataspace_dev_password
```

```bash
psql -h localhost -p 5532 -U dataspace -d dataspace_dev
```

Environnements disponibles :
- `dataspace_dev` - Développement (à utiliser en local)
- `dataspace_test` - Tests
- `dataspace_prod` - Production

---

## Versions

- **Apache Airflow**: 3.1.6
- **PostgREST**: 14 (API REST auto-générée)
- **Metabase**: 0.58.1 (visualisation des données)
- **PostgreSQL**: 16 (avec PostGIS pour la base de données ETL)
- **Python**: 3.11
- **Flyway**: 10 (migrations de base de données)

## Prérequis

- **Docker** >= 20.10
- **Docker Compose** v2 (intégré dans Docker Desktop ou `docker-compose-plugin`)
- **RAM** : ~2-3 Go par défaut (profile airflow), ~6 Go pour la stack complète (profile all)

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                         Docker Network                             │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  Airflow Standalone  :8080                                  │  │
│  │  (webserver + scheduler + triggerer)                        │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                           ▲                                        │
│                           │ depends_on                             │
│                           │                                        │
│  ┌─────────────┐   ┌──────┴──────┐   ┌────────────────┐          │
│  │ PostgreSQL  │   │   Flyway    │   │ PostgreSQL     │          │
│  │ (Airflow +  │   │ (migrations)│──▶│ + PostGIS      │          │
│  │  Metabase)  │   │  one-shot   │   │ (Data ETL)     │          │
│  │ :5533       │   └──────┬──────┘   │ :5532          │          │
│  └──────┬──────┘          │          └───────┬────────┘          │
│         │                 │ depends_on       │                    │
│         │                 ▼                  │                    │
│         │          ┌──────────────┐          │                    │
│         │          │  PostgREST   │──────────┘                    │
│         │          │  (API REST)  │  connecté en app_api          │
│         │          │  :3000       │                               │
│         │          └──────────────┘                               │
│         │                                                         │
│         │          ┌──────────────┐                               │
│         └─────────▶│  Metabase    │───────────────────────────────│
│           metadata │  (dataviz)   │  lit schéma dataviz           │
│                    │  :3001       │                               │
│                    └──────────────┘                               │
└───────────────────────────────────────────────────────────────────┘
```

### Ordre de démarrage

Services de base (toujours démarrés) :
1. **postgres-dataspace** démarre
2. **flyway** attend que postgres-dataspace soit healthy, puis exécute les migrations

Services conditionnels (selon le profile) :
3. **postgres-airflow** démarre (profiles: airflow, dataviz, all)
4. **postgrest**, **metabase**, **airflow** attendent flyway puis démarrent selon le profile choisi

## Installation

```bash
./scripts-dev/setup.sh
```

Ce script crée le `.env`, lance la stack avec le profile demandé (Airflow par défaut), attend que les services soient prêts, et affiche les infos de connexion.

### Profiles (stack légère)

La stack complète est lourde (~6 Go RAM). Utilisez les **profiles** pour ne lancer que ce dont vous avez besoin :

| Profile | Services | Cas d'usage |
|---------|----------|-------------|
| `airflow` | PostgreSQL + Flyway + Airflow | Développer des DAGs **(défaut)** |
| `api` | PostgreSQL + Flyway + PostgREST | Travailler sur l'API |
| `dataviz` | PostgreSQL + Flyway + Metabase | Visualisation des données |
| `all` | Tout | Stack complète |

```bash
# Développer des DAGs (défaut)
./scripts-dev/setup.sh
# ou explicitement
./scripts-dev/setup.sh --profile airflow

# Travailler sur l'API (PostgREST seul)
./scripts-dev/setup.sh --profile api

# Visualisation (Metabase seul)
./scripts-dev/setup.sh --profile dataviz

# Stack complète
./scripts-dev/setup.sh --profile all
```

### Reset

Pour purger les données et repartir de zéro :

```bash
./scripts-dev/setup.sh --reset

# Combinable avec un profile
./scripts-dev/setup.sh --reset --profile all
```

### Import des données pseudonymisées

Pour travailler avec des données réalistes (pseudonymisées), vous pouvez importer un dump :

1. Téléchargez l'archive `dataspace_pseudonym.tar.gz` depuis le drive
2. Placez-la dans le dossier `import-data/`
3. Lancez le setup avec l'option `--with-data` :

```bash
# Setup + import des données
./scripts-dev/setup.sh --with-data

# Reset complet + import des données
./scripts-dev/setup.sh --reset --with-data

# Combinable avec les profiles
./scripts-dev/setup.sh --profile all --with-data
```

Ou importez manuellement après un setup :

```bash
./scripts-dev/import-data.sh
```

Seuls les fichiers de données sont importés :
- `dataspace-02-data-admin-ref.sql` - Données admin et reference
- `dataspace-03-data-main.sql` - Données main (structures, personnes pseudonymisées)
- `dataspace-04-data-min.sql` - Données min (utilisateurs pseudonymisés)

L'archive est automatiquement supprimée après l'import.

## Installation Pas à Pas

Si vous préférez comprendre chaque étape plutôt que d'utiliser `setup.sh` :

### Étape 1 : Vérifier les prérequis

```bash
./scripts-dev/check-env.sh
```

### Étape 2 : Créer le fichier .env

```bash
cp .env.example .env
# Adapter AIRFLOW_UID à votre utilisateur
sed -i "s/AIRFLOW_UID=1000/AIRFLOW_UID=$(id -u)/" .env
```

### Étape 3 : Lancer la stack

```bash
docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml up -d
```

Au premier lancement, Docker va :
1. Télécharger les images (~1-2 Go)
2. Initialiser les bases de données
3. Exécuter les migrations Flyway
4. Créer l'utilisateur admin avec un mot de passe généré

### Étape 4 : Récupérer le mot de passe admin

**Important**: Dans Airflow 3.x, le mot de passe admin est généré automatiquement.

```bash
# Récupérer le mot de passe
docker compose -f docker-compose.dev.yml logs airflow | grep -i password
```

Le mot de passe apparaît dans une ligne comme :
```
standalone | Login with username: admin  password: XXXXXXXX
```

### Étape 5 : Importer les variables Airflow

```bash
./scripts-dev/import-variables.sh
```

Les variables sont définies dans `airflow-variables.dev.json`. Adaptez ce fichier si besoin.

### Étape 6 : Accéder à Airflow

Ouvrez http://localhost:8080 et connectez-vous avec :
- **Username**: `admin`
- **Password**: (récupéré à l'étape 4)

## Services

| Service | URL/Port | Description |
|---------|----------|-------------|
| Airflow UI | http://localhost:8080 | Interface web |
| PostgREST API | http://localhost:3000 | API REST (Swagger sans auth) |
| Metabase | http://localhost:3001 | Visualisation des données |
| PostgreSQL Airflow | localhost:5533 | Metadata Airflow + Metabase |
| PostgreSQL Data | localhost:5532 | Données ETL (avec PostGIS) |
| Flyway | - | Migrations DB (one-shot au démarrage) |

## Commandes Utiles

```bash
# Voir les logs en temps réel
docker compose -f docker-compose.dev.yml logs -f airflow

# Arrêter la stack (conserve les données)
docker compose -f docker-compose.dev.yml down

# Arrêter et supprimer les volumes (reset complet)
docker compose -f docker-compose.dev.yml down -v

# Redémarrer Airflow
docker compose -f docker-compose.dev.yml restart airflow

# Ouvrir un shell dans le conteneur Airflow
docker exec -it airflow bash

# Exécuter une commande Airflow
docker exec airflow airflow dags list
docker exec airflow airflow variables list

# Voir le mot de passe admin
docker compose -f docker-compose.dev.yml logs airflow | grep -i password
```

## PostgREST - API REST

PostgREST expose automatiquement les vues et fonctions du schéma `api` en endpoints REST. Voir `database/POSTGREST.md` pour la documentation complète de l'architecture.

### Accès

- **Swagger UI** : http://localhost:3000 (sans authentification)
- **API** : http://localhost:3000 (avec JWT)

### Token dev

Le script `setup.sh` crée automatiquement un rôle `postgrest_dev` avec accès à toutes les vues et fonctions du schéma `api`, ainsi qu'un JWT valide 1 an.

Le token est affiché à la fin du setup. Pour le régénérer manuellement :

```bash
docker exec postgres-dataspace psql -U dataspace -d dataspace_dev -tAc "
  SELECT auth.create_jwt(
    'dev-token',
    'postgrest_dev',
    (CURRENT_DATE + INTERVAL '1 year')::date,
    'dev-jwt-secret-key-min-32-chars!'
  );
"
```

### Exemples d'appels

```bash
# Variable avec le token (affiché par setup.sh)
TOKEN="<votre-token-dev>"

# Swagger / OpenAPI spec
curl http://localhost:3000/

# Lister les structures (GET sur une vue)
curl http://localhost:3000/structures \
  -H "Authorization: Bearer $TOKEN"

# Appeler une fonction RPC (POST)
curl -X POST http://localhost:3000/rpc/get_mediateur \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com"}'

# Filtrage PostgREST (query params)
curl "http://localhost:3000/carto?limit=10&order=nom.asc" \
  -H "Authorization: Bearer $TOKEN"
```

### Logs PostgREST

```bash
docker compose -f docker-compose.dev.yml logs -f postgrest
```

### Redémarrer PostgREST (après modification du schéma api)

```bash
docker compose -f docker-compose.dev.yml restart postgrest
```

PostgREST recharge aussi automatiquement le schéma quand une migration exécute `NOTIFY pgrst, 'reload schema';`.

---

## Metabase - Visualisation des données

Metabase permet de créer des dashboards et visualisations à partir des données du schéma `dataviz`.

### Accès

- **URL** : http://localhost:3001

### Premier lancement

Au premier démarrage, Metabase vous demande de créer un compte administrateur. Utilisez les identifiants de votre choix.

### Connecter Metabase à la base de données

1. Dans Metabase, allez dans **Settings > Admin > Databases > Add database**
2. Configurez la connexion :
   - **Database type**: PostgreSQL
   - **Display name**: DataSpace
   - **Host**: `postgres-dataspace`
   - **Port**: `5532`
   - **Database name**: `dataspace_dev`
   - **Username**: `dataspace`
   - **Password**: `dataspace_dev_password`
3. Cliquez sur **Save**

### Schéma dataviz

Les vues dédiées à Metabase sont dans le schéma `dataviz`. Après avoir connecté la base, vous pouvez créer des questions et dashboards basés sur ces vues.

### Logs Metabase

```bash
docker compose -f docker-compose.dev.yml logs -f metabase
```

---

## Connexion à PostgreSQL

### Base Airflow (metadata)
```bash
psql -h localhost -p 5533 -U airflow -d airflow
# Password: airflow
```

### Base Data (ETL avec PostGIS)
```bash
psql -h localhost -p 5532 -U dataspace -d dataspace_dev
# Password: dataspace_dev_password
```

## Flyway - Migrations de la Base de Données

### Fonctionnement

Flyway gère automatiquement les migrations de la base `postgres-dataspace` :

- **Au démarrage** : Flyway s'exécute automatiquement et applique toutes les migrations en attente
- **Airflow et PostgREST attendent** : Ces services ne démarrent qu'après que Flyway ait terminé avec succès
- **Idempotent** : Les migrations déjà appliquées sont ignorées

### Fichiers de migration

Les migrations se trouvent dans `database/migrations/` :

```
database/migrations/
├── V001_20250531__schema_import.sql      # Création schéma import
├── V002_20250531__schema_admin.sql       # Création schéma admin
├── V003_20250531__schema_reference.sql   # Création schéma reference
├── V004_20250531__schema_main.sql        # Création schéma main
├── V005_20250531__schema_dataviz.sql     # Création schéma dataviz
├── ...
├── V038_20251218__dataviz_audit_post_merge.sql
├── U001_20250531__schema_import.sql      # Undo migrations (rollback)
└── ...
```

- **V*.sql** : Migrations versionnées (appliquées dans l'ordre)
- **U*.sql** : Migrations undo (pour rollback)

### Créer une nouvelle migration

1. Créer un fichier SQL dans `database/migrations/` en respectant la convention de nommage :

```
V<NUM>_<DATE>__<description>.sql
```

- `V<NUM>` : numéro séquentiel (le dernier est V038, donc le prochain est **V039**)
- `<DATE>` : date au format `YYYYMMDD`
- `__` : **double underscore** obligatoire (séparateur Flyway)
- `<description>` : description en snake_case

Exemple :

```bash
database/migrations/V039_20260127__ajout_vue_api_exemple.sql
```

2. Écrire le SQL dans le fichier. Si la migration touche le schéma `api`, ajouter à la fin pour que PostgREST recharge son cache :

```sql
NOTIFY pgrst, 'reload schema';
```

3. Appliquer la migration :

```bash
# Manuellement
./scripts-dev/run-flyway.sh migrate

# Ou au prochain démarrage de la stack
./scripts-dev/setup.sh
```

4. (Optionnel) Créer un fichier undo correspondant `U039_20260127__ajout_vue_api_exemple.sql`. Les fichiers `U*.sql` ne sont pas exécutés automatiquement par Flyway (le Dockerfile filtre sur `V*.sql`), ils servent de référence pour un rollback manuel.

### Commandes Flyway

```bash
# Voir l'état des migrations
./scripts-dev/run-flyway.sh info

# Appliquer les migrations en attente
./scripts-dev/run-flyway.sh migrate

# Valider les migrations
./scripts-dev/run-flyway.sh validate

# Réparer après une erreur (checksum, etc.)
./scripts-dev/run-flyway.sh repair

# Voir les logs Flyway du dernier démarrage
docker compose -f docker-compose.dev.yml logs flyway
```

### Résolution de problèmes Flyway

#### Erreur de checksum
Si une migration a été modifiée après application :
```bash
./scripts-dev/run-flyway.sh repair
./scripts-dev/run-flyway.sh migrate
```

#### Réinitialiser complètement les migrations
```bash
# Supprimer le volume de données (PERTE DE DONNÉES!)
docker compose -f docker-compose.dev.yml down -v

# Relancer la stack
./scripts-dev/setup.sh
```

#### Flyway échoue au démarrage
```bash
# Vérifier les logs
docker compose -f docker-compose.dev.yml logs flyway

# Relancer uniquement Flyway
docker compose -f docker-compose.dev.yml up flyway
```

## Configuration des Connexions Airflow

Pour que les DAGs puissent se connecter à la base de données des données, créez une connexion Airflow :

1. Allez dans **Admin > Connections**
2. Cliquez sur **+** pour ajouter une connexion
3. Remplissez :
   - **Connection Id**: `sonum-dev-db`
   - **Connection Type**: Postgres
   - **Host**: `postgres-dataspace`
   - **Schema**: `dataspace_dev`
   - **Login**: `dataspace`
   - **Password**: `dataspace_dev_password`
   - **Port**: `5432`

## Troubleshooting

### Les DAGs ne s'affichent pas

1. Vérifiez les erreurs de syntaxe Python :
```bash
docker exec airflow airflow dags report
```

2. Vérifiez les logs :
```bash
docker compose -f docker-compose.dev.yml logs -f airflow
```

### Erreur de permissions

```bash
# Définir le bon UID
export AIRFLOW_UID=$(id -u)
docker compose -f docker-compose.dev.yml up -d
```

### Le webserver ne démarre pas

```bash
# Vérifier les logs complets
docker compose -f docker-compose.dev.yml logs airflow

# Vérifier la connexion à PostgreSQL
docker compose -f docker-compose.dev.yml logs postgres-airflow
```

### Réinitialiser complètement

```bash
docker compose -f docker-compose.dev.yml down -v
./scripts-dev/setup.sh
```

### Mot de passe admin perdu

Après un reset complet, un nouveau mot de passe sera généré :
```bash
docker compose -f docker-compose.dev.yml down -v
./scripts-dev/setup.sh
docker compose -f docker-compose.dev.yml logs airflow | grep -i password
```

## Structure des Fichiers

```
scripts/
├── .env.example              # Template variables d'environnement
├── .env                      # Variables d'environnement (créé automatiquement)
├── docker-compose.dev.yml    # Configuration Docker dev (Airflow, Flyway, PostgREST, Metabase)
├── Dockerfile.airflow        # Image Airflow avec dépendances Python pré-installées
├── airflow-variables.dev.json # Variables Airflow pour dev
├── scripts-dev/
│   ├── setup.sh              # Setup complet (à utiliser) - crée aussi le token dev PostgREST
│   ├── import-data.sh        # Import des données pseudonymisées
│   ├── init-databases.sql    # Init PostgreSQL dataspace (bases dev/test/prod, rôle app_api)
│   ├── init-airflow-db.sql   # Init PostgreSQL airflow (base metabase)
│   ├── run-flyway.sh         # Exécution manuelle de Flyway
│   ├── check-env.sh          # Vérification de l'environnement
│   └── import-variables.sh   # Import des variables Airflow
├── import-data/              # Dossier pour l'archive dataspace_pseudonym.tar.gz
├── database/
│   ├── flyway.toml           # Configuration Flyway
│   ├── POSTGREST.md          # Documentation architecture PostgREST
│   └── migrations/           # Scripts SQL de migration (~80 fichiers)
│       ├── V*.sql            # Migrations versionnées
│       └── U*.sql            # Migrations undo (rollback)
└── plugins/                  # Plugins Airflow (créé automatiquement)
```

## Notes sur Airflow 3.x

- Le mode **standalone** combine webserver, scheduler et triggerer dans un seul processus
- Le mot de passe admin est **toujours généré automatiquement** et affiché dans les logs
- Les providers doivent être installés séparément (`apache-airflow-providers-*`)
- La commande `airflow db migrate` remplace `airflow db init` et `airflow db upgrade`
