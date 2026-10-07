# SPEC DE RÉIMPLÉMENTATION — Couche `source` brute

> But de ce document : permettre de **refaire intégralement** la feature « couche source »
> sur une **branche neuve partie de `main` à jour**, sans cherry-pick ni rebase.
> Source d'origine (à ne PAS merger) : branche `refacto/import-donnee-brute`,
> commit `d1b8f4b` + travail non commité. Réimplémenter depuis cette spec, pas depuis le diff.

## Intention globale

Capturer les données **telles que reçues de chaque source**, avant toute transformation, pour :
- **Rejouer** un run passé sans rappeler la source externe
- **Tracer** les erreurs (comparer reçu vs chargé)
- **Auditer** l'évolution des données dans le temps

Principes directeurs (non négociables) :
- **Append-only** : jamais d'écrasement, chaque run ajoute ses lignes.
- **Aucune transformation** : valeurs brutes (strings, noms de colonnes d'origine) stockées en JSONB.
- **Strangler fig / non-intrusif** : chaque capture est un **dead-end parallèle**. Le pipeline existant
  continue de fonctionner **exactement** comme avant. Une capture qui échoue ne doit jamais bloquer l'aval.

## Pré-requis avant de coder : numérotation Flyway

⚠️ Au moment de la branche d'origine, `main` allait jusqu'à **V098** (avec **V096 libre**).
**Re-vérifier le max au moment de réimplémenter** (`main` a pu bouger) :
```
git ls-tree -r --name-only origin/main -- database/migrations/ | grep -oE 'V[0-9]+' | sort -V | tail -1
```
Puis numéroter les 7 migrations source à la suite. Numéros proposés (à ajuster) :

| Contenu | V (forward) | U (undo) |
|---|---|---|
| schéma `source` + table `idposte__conum` | V099 | U099 |
| tables `coop__*` | V100 | U100 |
| tables `ac__*` | V101 | U101 |
| tables zonages (`frr__zonage`, `qpv__zonage`) | V102 | U102 |
| table `carto__structures` | V103 | U103 |
| table `sirene__etablissements` | V104 | U104 |
| table `ban__adresses` | V105 | U105 |

Date dans le nom de fichier : utiliser la date de réimplémentation (`YYYYMMDD`).
Convention : `V<NUM>_<YYYYMMDD>__<desc_snake>.sql` + undo `U<NUM>_...`.

---

## Structure commune de TOUTES les tables `source`

Convention de nommage : `source.{source}__{entite}` (aligné sur `import.{source}__{table}`).
Toutes les tables partagent exactement ce DDL :

```sql
CREATE TABLE source.<source>__<entite> (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,   -- dag_run.run_id Airflow
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,   -- identifiant source (clé S3, endpoint, URL…)
    donnee      JSONB       NOT NULL    -- 1 ligne / 1 objet brut reçu
);
```

---

## LOT 1 — Schéma `source` + tables de capture (ex-commit d1b8f4b)

### Migration schéma + idposte (V099)

Crée le schéma, les GRANTS, et la première table. **Pas de migration de grants dédiée** :
on reproduit le pattern du schéma `import` (V001) via `ALTER DEFAULT PRIVILEGES`, hérité par
toutes les tables `source` créées **ensuite**. Donc cette migration DOIT être la 1re du lot.

```sql
CREATE SCHEMA IF NOT EXISTS source;
GRANT USAGE ON SCHEMA source TO app_python;
ALTER DEFAULT PRIVILEGES IN SCHEMA source
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO app_python;

CREATE TABLE source.idposte__conum (... structure commune ...);
```
Undo (U099) : `DROP SCHEMA IF EXISTS source CASCADE;`

### Migrations tables (V100→V103)

DDL structure commune pour chaque table. Undo = `DROP TABLE IF EXISTS source.<table>;` (ordre inverse).

| Migration | Tables créées |
|---|---|
| V100 source_coop | `coop__structures`, `coop__utilisateurs`, `coop__activites` |
| V101 source_aidants_connect | `ac__structures`, `ac__aidants` |
| V102 source_zonages | `frr__zonage`, `qpv__zonage` |
| V103 source_carto | `carto__structures` |

---

## LOT 2 — Hooks `write_to_source` dans les DAGs

Chaque DAG capture ses données brutes via une tâche **dead-end** branchée en parallèle.
Helper d'insertion (psycopg2 `execute_values`, append-only, JSONB) — pattern répété par DAG :

```python
from airflow.providers.postgres.hooks.postgres import PostgresHook
from psycopg2.extras import execute_values
import json

# rows = [(run_id, source_key, json.dumps(record, ensure_ascii=False)) ...]
hook = PostgresHook(postgres_conn_id=db_conn_id)
conn = hook.get_conn()
with conn.cursor() as cursor:
    execute_values(cursor,
        f"INSERT INTO source.{table} (run_id, source_key, donnee) VALUES %s", rows)
conn.commit()
# NE PAS fermer la connexion (pattern établi). Log: "[source] N lignes insérées dans source.X (run_id=...)"
```
Lire les CSV avec `pd.read_csv(path, dtype=str, keep_default_na=False)` (pas de NaN, tout en string).

### Par DAG

**`schema-idPoste.py`** — table `source.idposte__conum`
- `write_to_source(**context)` : lit `{working_dir}/conum.csv` (`sep=CSV_SEPARATOR`).
- `source_key` = clé S3 du fichier → **faire retourner `most_recent_key` par `download_from_s3`**
  (et `return local_file` dans le early-return), récupéré via `xcom_pull(task_ids="download_file")`.
- Topologie : `init_dir >> get_conum_file >> [write_to_source_task, process_data_conum_task]`
  (process_data_conum reste l'amont du reste du pipeline, inchangé).

**`coop-dag.py`** — tables `coop__structures`, `coop__utilisateurs`, `coop__activites`
- Helper `_write_csv_to_source(table, csv_path_or_paths, run_id, db_conn_id, source_key)`
  (gère 1 chemin ou une liste de chemins).
- 3 callables : `write_to_source_structures` (source_key `/api/v1/structures`),
  `_utilisateurs` (`/api/v1/utilisateurs`), `_activites` (source_key = `xcom_pull("build_activites_endpoint")`).
- XCom : `fetch_all_structures`, `fetch_all_utilisateurs`, `fetch_all_activites`.
- Edges : `fetch_structures_task >> write_to_source_structures_task` (idem users, activites). Dead-ends.

**`aidants-connect-dag.py`** — tables `ac__structures`, `ac__aidants`
- Helper module-level `_write_records_to_source(table, records, run_id, db_conn_id, source_key)`
  (reçoit une liste de **dicts**, pas un CSV — données déjà en mémoire via XCom).
- `write_to_source_ac_structures` : `xcom_pull("fetch_all_aidants_structures")["structures"]`,
  source_key = `STRUCTURES_ENDPOINT`.
- `write_to_source_ac_aidants` : `xcom_pull("fetch_all_aidants_personnes")["aidants"]`,
  source_key = `xcom_pull("build_aidants_endpoint")`.
- Note métier : fetch aidants **incrémental** → la table capture le **delta du run**, pas la vue complète.
- Edges : `fetch_all_aidants_structures >> write_to_source_ac_structures_task` ;
  `fetch_all_aidants_personnes >> write_to_source_ac_aidants_task`.

**`carto-dag-import.py`** — table `source.carto__structures`
- `write_to_source_carto` : lit le CSV mergé via `xcom_pull("merge_data.merge_files")`.
- ⚠️ `source_key` = **valeur de la colonne `source` de chaque ligne** du CSV mergé
  (`row.get("source", "")`), PAS `params.repo_url`. C'est l'origine data-inclusion/coop par ligne.
- Branché **après le merge, avant enrichissement/dédup** : capture le brut mednum-cli.
- Edges : `merge_data >> [write_to_source_carto_task, split_enrich_group]` puis
  `split_enrich_group >> dedup_group >> ...` (le dead-end ne doit pas s'intercaler dans le flux principal).
- Ajouter l'import `from airflow.providers.postgres.hooks.postgres import PostgresHook`.

**`zonage-frr-dag.py`** — table `source.frr__zonage`  (étaient « à faire », implémentés dans d1b8f4b)
- TaskFlow `@task write_to_source_frr(csv_path, download_url)` : `pd.read_csv(sep=";")`,
  source_key = URL de téléchargement. `get_current_context()` pour `db_conn_id`/`run_id`.
- Edges : `url >> xlsx_local >> csv_local >> [source_task, clean_frr_zonage]` ;
  `clean_frr_zonage >> insert_into_db`. Ajouter `import logging` + import PostgresHook.

**`zonage-qpv-dag.py`** — table `source.qpv__zonage`
- TaskFlow `@task write_to_source_qpv(csv_path)` : `pd.read_csv(sep=";")`, source_key = `QPV_URL`.
- Edge : `write_to_source_qpv(qpv_csv)` après `transform_to_qpv_csv`. Ajouter `import logging` + PostgresHook.

---

## LOT 3 — Couche source pour les APIs d'enrichissement (SIRENE / BAN)

Intention : capturer aussi le **brut renvoyé par les APIs INSEE et IGN/BAN**, au plus près de l'appel,
**avant** tout parsing/filtre. La capture est injectée **dans les classes batch partagées** via un
paramètre optionnel, pour ne PAS dupliquer la logique et garder CLI/tests intacts.

### Migrations (V104, V105)
- V104 `source.sirene__etablissements` (structure commune). Undo : drop.
- V105 `source.ban__adresses` (structure commune). Undo : drop.

### Nouveau module `etl/source_capture.py`
Fabrique de **sink** agnostique d'Airflow (prend une connexion psycopg2 ouverte) :
```python
SIRENE_TABLE = "source.sirene__etablissements"
BAN_TABLE = "source.ban__adresses"

def make_source_sink(conn, run_id, table):
    def sink(records, source_key):
        if not records: return
        rows = [(run_id, source_key, json.dumps(r, ensure_ascii=False, default=str)) for r in records]
        try:
            with conn.cursor() as cur:
                execute_values(cur,
                    f"INSERT INTO {table} (run_id, source_key, donnee) VALUES %s", rows)
            conn.commit()
            # log info "[source] N lignes insérées dans {table}"
        except Exception as e:
            logger.error("[source] échec capture %s ...", table); conn.rollback()  # n'interrompt jamais
    return sink
```
Clés : réutilise la connexion (commit par lot), **try/except qui avale l'erreur** (rollback + log), append-only.

### Param `source_sink` dans les classes batch
- `SireneBatch.__init__(..., source_sink=None)` : stocker `self.source_sink`.
  Dans `_fetch_batch`, **après `response.json()`, avant `_parse_response`** :
  `if self.source_sink: try: self.source_sink(data.get('etablissements', []), self.endpoint) except: log`.
- `GeocodeurBatch.__init__(..., source_sink=None)` : idem.
  Dans `_geocoder_batch`, **après `read_csv` du résultat, avant le filtre INSEE/score** :
  `if self.source_sink: try: self.source_sink(df_resultat.to_dict('records'), url) except: log`.
- **Défaut `None` → comportement strictement inchangé** (important : CLI, tests, autres appelants).

### Propagation via `etl/structure_enrichment.py`
Ajouter `source_sink_sirene=None, source_sink_ban=None` à :
`write_enriched_data_to_csv`, `_process_base_data_batch`, `_process_carto_data_batch`,
et les passer à `SireneBatch(... source_sink=source_sink_sirene)` / `GeocodeurBatch(source_sink=source_sink_ban)`.

### Câblage DAGs consommateurs
- `sirene-backfill-dag.py` : `from etl.source_capture import SIRENE_TABLE, make_source_sink` ;
  réutilise la **connexion courante** + `dag_run.run_id` ; `SireneBatch(api_key=..., source_sink=make_source_sink(conn, run_id, SIRENE_TABLE))`. Le sink commit par lot, avant l'UPDATE final.
- `carto-dag-import.py` (mode enrichissement) : construire les deux sinks (SIRENE+BAN) et les passer à
  `write_enriched_data_to_csv` — propager `db_conn_id` + `run_id` dans les commandes mappées.
- ⚠️ `scripts/regeocode_orphelines_carto.py` = **OBSOLÈTE** post-refonte phase 5 (écrit `main.structure` legacy).
  **NE PAS le câbler** (à supprimer par ailleurs).

---

## Vérification finale (avant push)
1. `./scripts-dev/run-flyway.sh info` puis `migrate` en local → schéma `source` + 9 tables, aucune collision de numéro.
2. `ruff check .` (CI `check-dag`) + chargement des DAGs (CI `test-dag`).
3. Vérifier qu'un run de chaque DAG insère bien dans `source.*` sans casser le flux import/main.
4. CHANGELOG.md + CHANGELOG-metier.md : une entrée `[source]` (tech + métier, voir CLAUDE.md).

## Découpage MR conseillé
- MR1 = Lot 1 + Lot 2 (schéma + captures DAG). MR2 = Lot 3 (APIs d'enrichissement).
  Ou tout en une MR si tu préfères livrer la couche source d'un bloc.
