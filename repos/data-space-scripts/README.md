Data Space - scripts
===

Dépôt pour les scripts de l'ETL : extraction depuis les sources, transformations, ingestion en base de données.

- [Data Space - scripts](#data-space---scripts)
- [Installation](#installation)
- [Gestion du DAG](#gestion-du-dag)
  - [Params](#params)
    - [Sélection de la connexion à la base de données](#sélection-de-la-connexion-à-la-base-de-données)
    - [Valeurs numériques entières (permettant valeur nulle)](#valeurs-numériques-entières-permettant-valeur-nulle)
    - [Valeurs numériques entières (sans valeur nulle)](#valeurs-numériques-entières-sans-valeur-nulle)
    - [Valeurs décimales (sans valeur nulle)](#valeurs-décimales-sans-valeur-nulle)
- [Comment développer ?](#comment-développer-)
- [Détail des étapes de traitement](#détail-des-étapes-de-traitement)
  - [1. Extract (etl/extract)](#1-extract-etlextract)
  - [2. Transform (etl/transform)](#2-transform-etltransform)
    - [Ingest (etl/transform/ingest)](#ingest-etltransformingest)
    - [Reconciliate (etl/transform/reconciliate)](#reconciliate-etltransformreconciliate)
  - [3. Load (elt/load)](#3-load-eltload)
- [Architecture globale](#architecture-globale)
  - [Base de données](#base-de-données)
- [Géocodage](#géocodage)
  - [Fichier csv en entrée](#fichier-csv-en-entrée)
  - [Fichier csv en sortie](#fichier-csv-en-sortie)
  - [URL de l'API BAN utilisée\*](#url-de-lapi-ban-utilisée)
  - [Score minimal de géocodage](#score-minimal-de-géocodage)
  - [Stratégie de géocodage](#stratégie-de-géocodage)
- [Données de références (codes insee, codes postaux, régions, départements, communes)](#données-de-références-codes-insee-codes-postaux-régions-départements-communes)
- [API](#api)
  - [Création d'un token](#création-dun-token)
    - [Les différentes étapes à réalisées pour créer le rôle plus son token](#les-différentes-étapes-à-réalisées-pour-créer-le-rôle-plus-son-token)
    - [La fonction `auth.create_role_n_token`](#la-fonction-authcreate_role_n_token)
  - [Ajout d'une nouvelle vue](#ajout-dune-nouvelle-vue)
- [Maintenance](#maintenance)


# Installation

1. Installer Python >= 3.10
2. Recommandé : installer et activer un environnement virtuel
3. Installer les dépendances avec `pip install -r requirements.txt`

# Gestion du DAG

Le projet s'appuie sur Airflow pour l'orchestration.
La CI/CD déploie les scripts après chaque merge sur la branche main. Tout DAG Airflow dans n'importe quel script du
repo sera instantié dans Airflow. Il n'y en a pour l'instant qu'un, `dag.py` à la racine.

A noter, les dépendances Python sur Airflow ne sont pas gérées par le fichier requirements.txt, il faut les installer
manuellement.

## Params

### Sélection de la connexion à la base de données

```py
from airflow.sdk import Param

"db_conn_id": Param(
    default="sonum-prod-db",
    type="string",
    enum=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"], # Restriction des valeurs à cette liste
    examples=["sonum-test-db", "sonum-dev-db", "sonum-prod-db"], # Liste pour l'UI
    title="Airflow DB connection id",
    description="Identifiant Airflow de la connexion à la base de données PostgreSQL.",
),
```

### Valeurs numériques entières (permettant valeur nulle)

```py
"id": Param(
  None, # Valeur par défaut
  type=["null", "integer"]
),
```

### Valeurs numériques entières (sans valeur nulle)

```py
"id": Param(
  0, # Valeur par défaut
  type="integer",
  minimum=1,
  maximum=42
),
```

### Valeurs décimales (sans valeur nulle)

```py
"similarity_threshold": Param(
    1.0,
    type="number",
    minimum=0.0,
    maximum=100.0,
),
```

Voir  [Core Concepts > Params](https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/params.html)

# Comment développer ?

Il n'existe pour l'instant pas d'instance de staging (ou dev) d'Airflow, et il est assez complexe d'installer Airflow
et Postgres localement. Nous recommandons donc pour l'instant de pousser tout changement sur la branche main pour
tester.

# Détail des étapes de traitement

Le dossier principal est `etl`, qui contient les étapes de traitement ensuite importées et orchestrées dans `dag.py`.
Chaque sous-dossier dans `etl` correspond à une étape de l'ETL.

## 1. Extract ([etl/extract](etl/extract))

Dans [etl/extract](etl/extract), on dépose les scripts servant à extraire les données des sources.
Plusieurs types de sources sont supportées, avec des connecteurs disponibles dans
[etl/extract/connectors/](etl/extract/connectors).
Chaque fichier devra ensuite correspondre à une source, et comprendra un dictionnaire de configuration pour chacune des
tables à ingérer. Chaque source sera écrite dans la base Postgres dans le schéma `import`, avec la convention
`{nom_du_produit_source}__{nom_de_la_table}`.

A cette étape il n'est pas nécessaire de transformer les données, on les copie juste telles que fournies.

## 2. Transform ([etl/transform](etl/transform))

Cette étape contient toutes les transformations pour passer des données brutes aux données finales.
Chaque sous-dossier devrai correspondre à une étape de traitement ; voici les étapes existantes mais il est bien
évidemment possible d'en ajouter lorsque de nouvelles sources le nécessiteront.

Cette étape ne réalise aucune écriture en base, elle se contente de fichiers CSV et JSON stockés dans un dossier
temporaire.

### Ingest ([etl/transform/ingest](etl/transform/ingest))

Cette étape récupère les données brutes et réalise les transformations propres à chaques tables : renommage des
colonnes, nettoyage, harmonisations des informations, ajout d'un UUID unique, etc.
Un script par source par simplicité, mais dans [utils.py](etl/transform/utils.py) on stocke les fonctions réutilisables.

### Reconciliate ([etl/transform/reconciliate](etl/transform/reconciliate))

Cet ensemble d'étapes sert à fusionner les tables de mêmes natures (par ex. les adresses, les personnes, les structures)
et à les dédupliquer. En détail (un script par étape cette fois-ci) :
1. [reindex.py](etl/transform/reconciliate/reindex.py) sert à remplacer les ID issus des bases de données sources
    (et surtout, les références) par l'UUID généré dans l'étape ingest. Cela garantit un format harmonisé des ID dans
    le data space.
2. [merge.py](etl/transform/reconciliate/merge.py) sert à fusionner les tables de mêmes natures.
3. [deduplicate.py](etl/transform/reconciliate/deduplicate.py) sert à dédupliquer les entrées de même natures jugées
    identiques (par exemple, deux personnes ou deux structures) et à propager cette dédulication en altérant les
    références si une entrée est dupliquée.

## 3. Load ([elt/load](etl/load))

Cette étape finale écrit les tables finales ainsi produites dans la base de données Postgres, dans le schéma `main`.
Un ensemble de contraintes sur les colonnes a été implémentée dans Postgres pour s'assurer de la bonne qualité de cette
donnée finale, par exemple des contraintes d'unicité de clés, de combinaisons de champs, ou de foreign key.

# Architecture globale

A compléter avec le schéma Airflow + BDD + Metabase + API

## Base de données

L'instance de base de données PostgreSQL est une instance managée.

Pour créer une base de données, avec la locale français, il faut utiliser le template0 :

```sql
CREATE DATABASE database
    LOCALE 'fr_FR.utf8'
    ENCODING UTF8
    TEMPLATE template0;
```

L'instance de bases de données est sauvegardée par l'outil intégré de Scaleway.

Une sauvegarde "externalisée" est possible en utilisant le DAG `database_backup`, qui réalise un dump complet de la base de donnée, le compresse plus le chiffre avec `openssl` avant de l'uploader dans un bucket S3.

La clef de chiffrement est stockée en variable dans AIrflow `OPENSSL_PASSWORD`, ainsi que dans Vaultwarden.

# Géocodage

Le script `geocoding.py` permet de géocoder les adresses avant l'importation en base.
Cela permet :
- l'ajout de la géométrie (latitude, longitude),
- l'ajout du code BAN (identifiant unique d'une adresse), qui facilite la gestion des doublons,
- l'uniformier les adresses,
- de disposer de l'écriture exacte de l'adresse.

Le script prend en paramètres :
- le fichier csv en entrée,
- le fichier csv en sortie,
- l'URL de l'API BAN utilisée*,
- le score minimal de géocodage*,
- la stratégie de géocodage*.

Ce qui donne :

```sh
./geocoding.py ./input.csv ./output.csv  https://api_url/search 0.6 permissive
```

## Fichier csv en entrée

Le fichier source doit être en `csv`.

Sa structuration doit être la suivante :

`id,pivot,nom,commune,code_postal,code_insee,adresse,complement_adresse,latitude,longitude,typologie,telephone,courriels,site_web,horaires,presentation_resume,presentation_detail,source,itinerance,structure_parente,date_maj,services,publics_specifiquement_adresses,prise_en_charge_specifique,frais_a_charge,dispositif_programmes_nationaux,formations_labels,autres_formations_labels,modalites_acces,modalites_accompagnement,fiche_acces_libre,prise_rdv`

## Fichier csv en sortie

Il aura la même structure de départ, avec de nouvelles colonnes à la fin.
- code_ban
- longitude (décimale)
- latitude (décimale)
- numero, le numéro de l'adresse dans la voie (entier)
- repetition, l'indice de répétition du numéro {bis, ter, A, B, ...} (texte)
- voie, le type et nom de voie (texte)
- ville (texte)
- code_postal (texte)
- code_insee (texte)

## URL de l'API BAN utilisée*

*Optionnel*, l'API BAN officielle sera utilisée par défaut : `https://data.geopf.fr/geocodage/search`.

## Score minimal de géocodage

*Optionnel*, par défaut `0,6`.

Permet de maintenir un bon niveau d’exigence de géocodage.

## Stratégie de géocodage

*Optionnel*, par défaut `strict`.

Deux stratégies de géocodage sont disponibles :
- strict : seuls les résultats de type: `housenumber` seront considérés,
- permissive :
  - les résultats de type: `housenumber` seront considérés (car sont les plus précis),
  - les résultats de type: `locality` ou `street` sont considérés uniquement si l'adresse n'a pas de numéro (notamment place et lieu-dit).

Ce qui donne :

```json
{"status": "progress", "duration": 1.82, "total": 100, "success": 75, "params": {"api": "http://192.168.1.2/search", "inputfile": "./data/input.csv", "score_min": 0.6, "geocoding_strategy": "strict"}, "perf": {"efficacity": 75.0, "score_avg": 0.97, "addrPerSecond": 54.95}}
```

Dans tous les cas, elles sont affichées en fin d'execution. Exemple :

```json
Global statistics
{
 "status": "finish",
 "duration": 1.22,
 "total": 57,
 "success": 50,
 "params": {
  "api": "http://192.168.1.2/search",
  "inputfile": "./data/input.csv",
  "score_min": 0.6,
  "geocoding_strategy": "strict"
 },
 "perf": {
  "efficacity": 87.72,
  "score_avg": 0.95,
  "addrPerSecond": 46.72
 }
}
```

Avec :

- status, le status
- duration, la durée de géocodage
- total, le nombre d'adresses traitées
- success, le nombre d'adresses géocodées
- params, les paramètres d'execution du script, avec :
    - api, l'URL de l'API utilisée
    - inputfile, le fichier source
    - score_min, le score minimal de géocodage
    - geocoding_strategy, la stratégie de géocodage
- perf, le bilan der performances, avec :
    - efficacity, le pourcentage d'adresses géocodées
    - score_avg, le score moyen de géocodage
    - addrPerSecond, la moyenne d'adresses par seconde


# Données de références (codes insee, codes postaux, régions, départements, communes)

Pour permettre aux DAGs `init_ref_data` de fonctionner correctement et d'intégrer les données, notamment géographique, il est nécessaire d'installer des paquets sur le serveur Airflow.

```sh
# Require 7zip
sudo apt install 7zip

# Require Postgis for shp2pgsql
sudo apt install postgis
```

---

# API

Une API REST en utilisant `PostgREST` permet d'exposer des tables et/ou vues de la base de données.


## Création d'un token

Les tokens étant liés à un rôle PostgreSQL, il est judicieux de créer un rôle pour chacune des structures utilisatrices de l'API, il est ainsi possible de limiter les droits sur des vues spécifiques.

Afin de garantir un certaine lisibilité dans les rôles PostgreSQL, la convention de nommage suivante est proposée :

postgrest_[nom de l'entité]_[usage dev/prod produit/site]

### Les différentes étapes à réalisées pour créer le rôle plus son token

La fonction `auth.create_role_n_token`, décrite après permet de réaliser toutes ces requêtes en appelant une seule fonction.

```sql
CREATE ROLE postgrest_entite_usage NOLOGIN;

COMMENT ON ROLE postgrest_entite_usage IS 'PostgREST xxxxxx role';


-- Allow app_api impersonate postgrest_entite_usage
GRANT postgrest_entite_usage TO app_api;

-- Need Usage on api schema to access to view(s)
-- Need Usage on auth schema to access to table `token` and `check_token` function
GRANT USAGE ON SCHEMA auth, api TO postgrest_entite_usage;
GRANT EXECUTE ON FUNCTION auth.check_token TO postgrest_entite_usage;
GRANT SELECT ON TABLE auth.token TO postgrest_entite_usage;

-- Add SELECT privileges on view(s)
GRANT SELECT ON TABLE auth.new_view TO postgrest_entite_usage;

-- Generate the JSON Web Token (l'id du token (permettant sa déactivation), PostgreSQL role, datetime d'expiration, 'le SECRET de PostgREST')
SELECT auth.create_jwt('entity-usage-001', 'postgrest_entite_usage', '2025-12-31 23:59:59', 'POSTGREST_SECRET');

-- Add the token declaration in `auth.token`
SELECT auth.add_token('entity-usage-001', 'postgrest_entite_usage', 'Entity usage token. Until 2025-12-31');
```

### La fonction `auth.create_role_n_token`

Cette fonction va créer le rôle s'il n'existe pas, puis son token.

Ensuite il conviendra de donner les droits à ce rôle.

```sql
SELECT auth.create_role_n_token(role_name, role_description, token_id, postgrest_secret, expiration_date, token_description);

-- Add SELECT privileges on view(s)
GRANT SELECT ON TABLE api.xxx TO role_name;
```


## Ajout d'une nouvelle vue

Afin d'exposer des données via l'API, il faut créer une vue dans le schéma `api`.
Puis données les droits en `SELECT` sur la vue en question au(x) rôle(s) qui doivent pouvoir y accéder.

`PostgREST` réalisant une mise en cache du schéma de la base de données, il est nécessaire du lui envoyer une notification `NOTIFY` pour qui mettre à jour son cache, sous peine de ne pas voir les modifications dans l'API

```sql
CREATE OR REPLACE VIEW api.new_view AS (
    SELECT *
    FROM table
);

-- All comments will be used by PostgREST as API documentation
COMMENT ON VIEW api.new_view IS 'Blablabla.';

COMMENT ON column api.new_view.column_xyz IS 'Blablabla.';

-- Add privilege for specific role(s)
GRANT SELECT ON TABLE api.new_view TO postgrest_entite_usage;

-- Send notification to PostgREST to reload the DB schema
NOTIFY pgrst, 'reload schema';
```

# Maintenance

Apache Airflow est très verbeux au niveau des logs. Ce qui peut remplir le disque de la VM et finir par faire crasher le système.

Il y a deux types de données à purger :
- les fichiers de logs sur le disque `/opt/airflow/logs/`,
- les log et les xcom stockés en base de données.

Pour les fichiers de logs, le DAG `airflow_log_cleanner` permet de supprimer les fichiers plus ancien que la durée fournie en paramètre (défaut 90j).
Ce DAG est programmé pour s'exécuter toute les semaines.

**Nota :** En revanche, il ne peut pas faire la purge de la base de données. Un mécanisme de sécurité empêche Airflow de purge sa propore base de données.
Il faudra donc l'exécuter manuellement ou le programmer.

Pour des données en base, le script bash `airflow_db_cleanner.sh` permet de spécifier les tables à purger (défaut log et xcom) et la durée de conservation des données.
