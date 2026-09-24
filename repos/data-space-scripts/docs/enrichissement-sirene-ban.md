# Enrichissement SIRENE + BAN — pipeline transverse

> Doc transverse à 3 sources : Coop, schema-idPoste, Aidants Connect.
> Carto a son propre flow d'enrichissement via mednum-cli + batch (cf [`cartographie-nationale.md`](cartographie-nationale.md)).
> Pour la précédence adresse SIRENE/BAN et la sémantique source, voir `ENRICHISSEMENT_ADRESSE.md` (MR en cours sur `fix/precedence-adresse-sirene-ban`).

## Vue d'ensemble

L'enrichissement transverse applique deux APIs publiques en batch pour complémenter les données sources incomplètes :

1. **SIRENE** (API INSEE) — identité légale via le SIRET : état administratif, code APE, catégorie juridique, dénomination.
2. **BAN** (Base Adresse Nationale, API IGN Géoplateforme) — géolocalisation et normalisation d'adresse (clef interop, code BAN, voie, commune, code INSEE).

Trois sources (Coop, schema-idPoste, Aidants Connect) partagent le pipeline batch via `etl/structure_enrichment.py::write_enriched_data_to_csv()` qui dispatch selon `data_type`.

Cartographie nationale traverse le même enrichissement via `_process_carto_data_batch()` mais avec spécificités (séparateur CSV `,`, colonnes préfixées `ban_*`, retry BAN sans `code_insee` désactivable).

## SireneBatch (`etl/sirene_batch.py`)

### Initialisation et méthode

```python
sirene = SireneBatch(api_key='<SIRENE_API_KEY>')
df_enrichi = sirene.enrichir_dataframe(
    df,
    colonne_id='id',
    colonne_siret='siret',
    batch_size=1000  # défaut SIRENE_BATCH_SIZE
)
```

- `api_key` : optionnel ; défaut `os.environ.get('SIRENE_API_KEY')` ; lève `ValueError` si absent (`etl/sirene_batch.py:84-85`).
- Endpoint défaut : `https://api.insee.fr/api-sirene/3.11/siret`.

### Colonnes produites

`id_source`, `siret_sirene`, `etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`, `adresse_sirene`, `code_insee_sirene`, `code_postal_sirene`, `date_creation_sirene`, `tranche_effectifs_sirene`, `sirene_trouve` (BOOL).

### Stratégie batch et rate limit

- **Batch size** : 1 000 SIRET par requête.
- **Rate limit** : 30 req/min → 2s entre batches (`etl/sirene_batch.py:31, 221`).
- **Normalisation SIRET** : pad 0 à gauche jusqu'à 14 chiffres ; rejette `'00000000000000'` ou non-numériques.
- **Déduplication intra-batch** : SIRET dupliqués groupés en une seule requête API, résultat appliqué à tous les `id_source` partageant le SIRET.
- **Retry** : 3 tentatives, exponential backoff `min(2 * 2^attempt, 60)s`. Erreurs 401 (clé invalide) levées explicitement, 404 (pas de résultat) → `{}`, 429 (rate limit) → backoff.

> ⚠️ **À valider (Q15c)** : commentaire `etl/sirene_batch.py:10` mentionne "API limite à 100 résultats", mais batch_size = 1000. Le code semble grouper via clause OR — limite réelle INSEE à confirmer.

## GeocodeurBatch (`etl/geocoding_batch.py`)

### Initialisation et méthode

```python
geocodeur = GeocodeurBatch()  # pas de clé API
df_geocode = geocodeur.geocoder_dataframe(
    df,
    colonne_id='id',
    colonne_adresse='adresse',
    colonne_code_postal='cp',     # optionnel
    colonne_code_insee='insee',   # optionnel — applique filtre géographique
    batch_size=10000,
)
```

### Colonnes produites

`id_source`, `clef_interop`, `code_ban`, `numero_voie`, `nom_voie`, `nom_commune`, `code_postal_geocode`, `code_insee_geocode`, `longitude`, `latitude`, `score_geocodage`, `label_geocodage`, `geom` (WKT POINT WGS84), `geocodage_valide` (BOOL : score >= score_minimum).

### Stratégie batch et rate limit

- **Batch size** : 10 000 adresses par requête (multipart CSV envoyée à `/search/csv`).
- **Rate limit** : limite API IGN 50 req/s ; côté code `RATE_LIMIT_DELAY = 0.1s` entre batches (`etl/geocoding_batch.py:34`) → ~10 req/s appliqués (marge confortable sous la limite).
- **Score minimum** : défaut 0.5 (configurable). Score < min → ligne marquée `geocodage_valide=FALSE` mais **insérée quand même**.
- **Filtre INSEE** : si `colonne_code_insee` fournie ET résultat BAN diffère du code INSEE recherché → ligne rejetée (compteur `nb_insee_mismatch`).

⚠️ **Pas de retry natif** (contrairement à SIRENE). En cas d'échec batch, lignes vides insérées.

## Orchestration commune (`etl/structure_enrichment.py`)

Point d'entrée unifié :

```python
write_enriched_data_to_csv(input_csv, output_csv, api_key, data_type)
```

Dispatch :
- `data_type == 'base'` → `_process_base_data_batch()` — Coop, schema-idPoste, Aidants Connect
- `data_type == 'carto'` → `_process_carto_data_batch()` — Cartographie nationale
- Autres → mode legacy ligne par ligne (non documenté ici)

### `_process_base_data_batch()` (Coop / schema-idPoste / AC)

1. Charge CSV (séparateur `;`).
2. Génère `_row_id` si absent.
3. **SIRENE batch** : filtre lignes avec `siret` non-vide, appelle `SireneBatch.enrichir_dataframe`, merge sur `_row_id`. Colonnes ajoutées : `etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`, `adresse_sirene`, `code_insee_sirene`.
4. **BAN batch** : filtre lignes avec `adresse` non-vide, appelle `GeocodeurBatch.geocoder_dataframe` (`colonne_code_insee='code_insee'` si présente), merge. Colonnes ajoutées : `numero_voie`, `nom_voie`, `nom_commune`, `code_postal_geocode → code_postal`, `code_insee_geocode → code_insee`, `longitude`, `latitude`, `geom`, `clef_interop`, `code_ban`.
5. Dérive `departement` depuis 2 premiers chiffres `code_insee` ou `code_postal`.
6. Nettoie colonnes temporaires (`_row_id`, `adresse_recherche`, `longitude`, `latitude`).
7. Écrit CSV enrichi.

### `_process_carto_data_batch()` (Cartographie)

Différences vs `_base` :
- Séparateur CSV `,` (virgule).
- Enrichissement SIRENE via colonne `pivot` (peut être SIRET 14 chiffres OU RNA `^W[0-9]{9}$`), pas `siret`.
- Renommage colonnes BAN avec préfixe `ban_*` (`clef_interop → ban_clef_interop`, `code_ban → ban_code_ban`, etc.).
- Colonne `ban_repetition` ajoutée manuellement (None) car non fournie par API batch.
- **Retry BAN sans `code_insee`** (fix `44e159f`) : si une ligne avec adresse non-vide n'a pas de résultat BAN ET pas de coords mednum-cli, retry sans `code_insee`. **Désactivé si mednum-cli a déjà fourni des coordonnées** (sinon risque de matcher un homonyme dans un autre département — cf bug `0a77db0`).

## Stratégies de fraîcheur par source

### Coop

`_should_enrich_structure(coop_id, map_coop, cutoff_date)` (`coop-dag.py:108-140`) :

```python
# Si coop_id absent ou pas de SIRET en base → skip
# Si last_sirene_enrich_at NULL → enrichir (1ère fois)
# Si last_sirene_enrich_at <= cutoff_date → enrichir (re-enrichir)
# Sinon → skip
```

Cutoff : `pendulum.now("UTC").subtract(months=4).date()`. Le code teste `last_p.date() <= cutoff_date` (`coop-dag.py:135`) → **re-enrichir si le dernier enrichissement remonte à plus de 4 mois** (skip sinon).

`map_coop` chargé depuis `main.structure` par `structure_coop_id` avec colonnes (`siret`, `last_sirene_enrich_at`).

### schema-idPoste

⚠️ **Pas de cutoff identifié** — appel direct `write_enriched_data_to_csv(structure_data, output_file, api_key, "base")` (`schema-idPoste.py:148`). Enrichissement systématique de toutes les structures à chaque run.

À valider avec l'équipe (Q15e) : volontaire (fraîcheur maximale) ou par défaut (cutoff non implémenté) ?

### Aidants Connect

`_should_enrich_structure_ac(ac_id, map_ac, cutoff_date)` — identique à Coop, cutoff 4 mois sur `last_sirene_enrich_at`.

Particularité AC : **dérivation `code_insee`** depuis `(code_postal, nom_commune)` via `admin.insee_cp × admin.commune` quand absent côté API (fix `2474f9c`). Sans cette dérivation, BAN matche un homonyme arbitraire en France.

### Cartographie nationale

Pas de cutoff. Enrichissement systématique (`TRUNCATE import.carto` à chaque run, rejeu entier).

## Champ `last_sirene_enrich_at` (`main.structure`)

Posé après enrichissement par les DAGs qui ont une stratégie de fraîcheur.

État vérifié (synthèse mai 2026, ex-Q15 résolu) :

- ✅ **Coop** — pose `last_sirene_enrich_at = now_ts` dans le batch UPDATE post-enrichissement (`coop-dag.py:405`).
- ✅ **Aidants Connect** — utilisé en lecture (cutoff 4 mois via `_should_enrich_structure_ac`) et en écriture après enrichissement.
- ❌ **schema-idPoste** — pas de cutoff, enrichissement systématique à chaque run, champ pas alimenté.
- ❌ **Cartographie nationale** — TRUNCATE + rejeu intégral à chaque run, pas de cutoff, champ pas alimenté.

Décision ouverte (Q19 dans [`questions-metier-en-cours.md`](questions-metier-en-cours.md)) : faut-il harmoniser pour que les 4 DAGs alimentent ce champ et permettent un cutoff partagé ?

> Note : la question chapeau Q15 a été retirée de `questions-metier-en-cours.md` après résolution ; Q19 (ex Q15 bis) subsiste sur l'harmonisation.

## Pièges identifiés

1. **Token SIRENE absent — comportement asymétrique selon DAG** :
   - **Coop** (`coop-dag.py:299-301`) et **Aidants Connect** (`aidants-connect-dag.py:373-375`) utilisent `Variable.get("API_SIRENE_TOKEN", default_var=None)` puis log WARNING + enrichissement SIRENE skippé (le DAG continue avec données partielles, vs fail-fast).
   - **schema-idPoste** (`schema-idPoste.py:137`) et **Carto** (`carto-dag-import.py:103`) appellent `Variable.get("API_SIRENE_TOKEN")` sans `default_var` → **lèvent immédiatement** `KeyError` si la variable manque (déjà fail-fast).
   À aligner : soit harmoniser les 4 DAGs sur fail-fast au démarrage, soit documenter explicitement l'asymétrie. Voir notes amélioration dans `questions-metier-en-cours.md`.

2. **Retry BAN sans `code_insee`** (Cartographie) — désactivé si mednum-cli a fourni des coords (sinon risque de déporter un lieu dans le mauvais département, fix `44e159f`). Risque résiduel si code INSEE recherché ne correspond pas exactement à celui de la BAN (décalage administratif, fusion commune).

3. **Dérivation `code_insee` AC** — lookup `(code_postal, nom_commune)` avec normalisation accents/casse. Si commune inconnue ou alias divergent → code INSEE non dérivé → BAN ne filtre pas géographiquement. Voir Q12.

4. **Nettoyage colonnes temporaires** — champs `_row_id`, `adresse_recherche`, `longitude`, `latitude`, `score_geocodage` (Carto) supprimés avant écriture CSV. Risque si traitement aval attend ces colonnes.

5. **Batch size SIRENE 1000 vs commentaire 100** — à clarifier (Q15c).

6. **`ban_repetition` toujours NULL côté Carto** — non fourni par API batch (Q15f).

## Questions ⚠️ à valider

> Sous-questions internes à ce doc (scope : enrichissement transverse).
> La question chapeau dans [`questions-metier-en-cours.md`](questions-metier-en-cours.md) est Q19 (ex Q15 bis, harmonisation des stratégies de fraîcheur). L'ancienne Q15 (qui posait `last_sirene_enrich_at` ?) a été retirée — résolution ci-dessus.

| Q | Sujet | Référence code | Statut |
|---|---|---|---|
| Q15.1 | `last_sirene_enrich_at` posée par toutes les sources ? | `coop-dag.py:405`, `schema-idPoste.py:148`, `carto-dag-import.py` | **Résolu** : Coop ✅, AC ✅, schema-idPoste ❌, Carto ❌ (cf §"Champ `last_sirene_enrich_at`" ci-dessus) |
| Q15.2 | Fail-fast token SIRENE absent — comportement à harmoniser ? | `coop-dag.py:299`, `aidants-connect-dag.py:373`, `schema-idPoste.py:137`, `carto-dag-import.py:103` | **Résolu sur les faits** : Coop+AC skippent avec WARNING, idposte+Carto déjà fail-fast. Décision d'harmonisation ouverte (cf `questions-metier-en-cours.md` Q19) |
| Q15.3 | Batch size SIRENE 1000 vs commentaire mentionnant 100 — limite réelle INSEE ? | `etl/sirene_batch.py:10,30` | Ouvert |
| Q15.4 | Cutoff 4 mois — justifié métier ou empirique ? | `coop-dag.py:296`, `aidants-connect-dag.py:370` | Ouvert |
| Q15.5 | schema-idPoste enrichit systématiquement (pas de cutoff) — voulu ou par défaut ? | `schema-idPoste.py:137-150` | Ouvert (constat factuel établi, intention métier à valider) |
| Q15.6 | `ban_repetition` toujours NULL — API BAN ne fournit pas en batch ? | `etl/structure_enrichment.py:521-523` | Ouvert |
