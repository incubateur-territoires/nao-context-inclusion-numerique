# 15 — Pattern d'ingestion de référence ("bronze d'abord")

← [Retour au document central](README.md)

## Pourquoi cette fiche

La couche `source` (bronze, fiche [01](architecture-medallion.md)) existe désormais en
base. Mais tous les flux ne l'utilisent pas de la même manière : certains capturent du
transformé, d'autres capturent après coup, d'autres pas du tout — et un seul consommateur
lit réellement le bronze. Cette fiche fixe **le pattern cible d'un flux d'ingestion**, dont
l'implémentation de référence est le flux accompagnements AC — historiquement le DAG
dédié `aidants-connect-accompagnements`, fusionné le 2026-07-31 dans le DAG quotidien
`aidants-connect-import` (tâches `stage_accompagnements` / `load_accompagnements` de
`aidants-connect-dag.py`) — et dresse l'état de conformité de chaque flux.

C'est la doctrine d'harmonisation : tout nouveau flux suit ce pattern, tout flux existant
migre vers lui (au rythme de la feuille de route, fiche [08](../chantiers/plateforme-data/feuille-de-route.md)).

## Les trois règles

### 1. L'extract capture le brut, et ne fait que ça

L'opérateur de fetch écrit le payload **tel que reçu** (page par page pour une API
paginée) dans `source.{source}__{entite}`, **avant toute transformation** — y compris le
typage, le renommage ou le "petit nettoyage". Concrètement, avec le connecteur existant :

```python
fetch = APIClientOperator(
    task_id="fetch_...",
    endpoint=ENDPOINT,
    # Capture brute in-operator, page par page :
    source_table="source.ac__aidants",
    source_db_conn_id="{{ params['db_conn_id'] }}",
    # Pas de payload en XCom (règle 2) :
    do_xcom_push=False,
)
```

Le brut est en base même si l'aval échoue : un bug de transform n'est jamais une perte de
données. Corollaire : **plus de logique métier dans l'extract** (`_transform_data` a
vocation à se vider — la transformation appartient à l'aval, règle 3).

### 2. Pas de XCom, pas de fichier intermédiaire : la base est l'interface

Les tâches ne se passent **rien** en mémoire ni en CSV temporaire. Le couplage
fetch → load passe par la base, via deux clés :

- **`run_id`** — isole les données de CE dag_run (rejouable, parallélisable) ;
- **`source_key`** — identifie le sous-flux dans la table (endpoint exact, nom de
  fichier, clé S3…). Indispensable quand deux DAGs alimentent la même table : le
  snapshot mensuel AC (`source_key` = endpoint nu) ne collisionne pas avec le delta
  quotidien (`source_key` = endpoint + filtre `?updated_at__gte=`).

### 3. Transform + load = un consommateur de la couche source

L'aval lit le bronze du run courant et upserte de façon idempotente :

```sql
SELECT donnee->>'id', donnee->'get_supports_number_last_six_months'
FROM source.ac__aidants
WHERE run_id = %s AND source_key = %s
ORDER BY ingested_at;   -- en cas de re-capture, la plus récente gagne
```

puis `INSERT ... ON CONFLICT ... DO UPDATE` vers `main.*` (ou `staging.*` quand la
couche silver existera, fiche [01](architecture-medallion.md)). La transformation est
rejouable sur n'importe quel run passé **sans re-fetcher la source**.

## Ce que le pattern achète

| Propriété | Concrètement |
|---|---|
| **Auditabilité** | Chaque ligne de `main.*` est retraçable au payload brut qui l'a produite (`run_id`). L'incident `is_visible` (`9d19646`, 24 835 personnes exposées) n'était **pas** investigable faute de brut — avec ce pattern, une requête aurait suffi. |
| **Rejouabilité** | Bug de transform ou nouveau champ à exploiter : on re-transforme un run passé, sans dépendre de la disponibilité de la source. |
| **Découplage** | Fetch et load sont indépendants ; un échec de load ne perd pas le fetch ; on peut re-lancer le load seul. |
| **Observabilité** | La volumétrie par (`run_id`, `source_key`) est requêtable — base des gardes volumétriques (fiche [06](observabilite-lineage.md)) qui auraient signalé le spike coop de 218 887 modifications (2026-07-22). |

## État de conformité par flux (2026-07-27)

Constats détaillés et datés dans les [contrats de flux](../../contracts/README.md).

| Flux | Capture brute | Pré-transform | Load depuis `source.*` | Écart principal |
|---|---|---|---|---|
| **ac accompagnements mensuels** | ✔ in-operator | ✔ | ✔ | — (référence) |
| **ac__aidants / ac__structures** (quotidien) | ✔ in-operator | ✔ | ✘ XCom | L'ingest consomme le XCom transformé ; schéma bronze hétérogène (anciens runs post-transform) |
| **idposte__conum** | ✔ CSV tel quel | ✔ | ✘ fichier | Load depuis le fichier de travail, pas depuis `source.*` |
| **coop** (structures, utilisateurs, activites) | ⚠ post-transform | ✘ | ✘ XCom/CSV | Le brut API n'existe nulle part (booléens `'True'`, tableaux re-sérialisés) ; transform dans l'extract |
| **carto__structures** | ⚠ post-chargement | ✘ | ✘ | Capture = `SELECT * FROM import.carto` : les lignes rejetées à l'entrée ne sont jamais capturées |
| **frr / qpv (zonages)** | ⚠ post-parsing | ✘ | ✘ | Capture après lecture XLSX/GeoJSON et sélection de colonnes |
| **sirene__etablissements** | ✔ partielle | ✔ | n/a (enrichissement) | Capturé seulement sur la voie `sirene-backfill` ; les enrichissements carto/idposte passent `source_sink=None` |
| **ban__adresses** | ✘ table vide | — | — | Sink prévu (`GeocodeurBatch`), jamais branché par aucun appelant |

## Chemin de migration d'un flux existant

Ordre recommandé, chaque étape étant livrable seule :

1. **Brancher/corriger la capture brute** (in-operator, pré-transform). Pour les flux à
   capture post-transform, c'est un changement de point d'appel, pas de logique.
2. **Basculer le load sur `source.*`** (`run_id` + `source_key`), en gardant la
   transformation identique — diff attendu vide sur `main.*` (test de non-régression
   naturel, fiche [03](qualite-donnees.md)).
3. **Vider `_transform_data`** pour ce flux : la logique migre dans le consommateur
   (puis, à terme, en SQL — fiche [05](transformations-elt-dbt.md)).
4. **Marquer la bascule dans le contrat** (`contracts/*.yml`, section `produit`) et le
   `CHANGELOG.md`.

Priorité suggérée : coop (le brut n'existe nulle part et c'est le plus gros flux),
puis BAN (câblage trivial du sink existant), puis carto, puis l'alignement AC quotidien.

## Pièges connus

- **Migrer à moitié** : capture nouvelle + load ancien laisse le schéma bronze hétérogène
  (cas AC actuel : les consommateurs doivent discriminer runs bruts / transformés).
  Migrer flux par flux, mais les deux bouts à la fois.
- **`source_key` trop vague** : sans clé discriminante, deux sous-flux d'une même table
  deviennent indissociables. La règle : `source_key` = ce qui identifie la requête
  (endpoint + filtres) ou le fichier exact.
- **Oublier `ORDER BY ingested_at`** côté consommateur : le bronze est append-only, les
  re-captures d'un même enregistrement sont normales — la plus récente doit gagner.
- **Nettoyer "juste un peu" à la capture** : le bronze est brut ou il ne sert à rien
  (fiche [01](architecture-medallion.md)).

## Références

- Maxime Beauchemin — *Functional Data Engineering* (immutabilité, rejouabilité)
- Fiche [01](architecture-medallion.md) (couches), [06](observabilite-lineage.md)
  (ce que le bronze rend observable), [contrats de flux](../../contracts/README.md) (état réel par flux)
