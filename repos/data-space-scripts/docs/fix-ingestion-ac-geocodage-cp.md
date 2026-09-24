# Brief d'implémentation — géocoder les structures AC sur le CP (pas le code_insee)

> Spec auto-suffisante pour une session d'implémentation dédiée. Décision et
> preuves établies juin 2026 (cf mémoires `project_ac_code_insee_source_pollue`
> et `project_sa_adresse_pipeline_ban_source`).

## Décision
Dans l'ingestion Aidants Connect, **filtrer le géocodeur BAN par `code_postal`
(postcode) au lieu de `code_insee` (citycode)**. Le `code_insee` d'AC vient brut
de l'API (`city_insee_code`) et est pollué (placeholder `57490`/Moyenvic,
désync avec `city`/`zipcode`) ; le CP, lui, est fiable.

## Preuve (test A/B réel, géocodage BAN sur données AC réelles)
| Population | A `citycode`=insee (actuel) | B `postcode`=CP (cible) |
|---|---:|---:|
| AC en écart (910) | 34% iso-SIRENE | **69%** |
| AC déjà conformes (696) | 70% | **92%** |

Régressions de B sur les déjà-bons : **2,9%** (CP multi-communes où l'insee
correct désambiguïsait — acceptable, et en partie de faux négatifs siège≠site).
La variante hybride « insee si même dépt, sinon CP » est moins bonne (43%) :
rejetée.

## Changements à faire (`aidants-connect-dag.py`)

1. **Appel géocodeur** (~l.252-257) : remplacer le filtre insee par le filtre CP.
   ```python
   df_geocode = geocodeur_instance.geocoder_dataframe(
       df_chunk, colonne_id="_row_idx", colonne_adresse="adresse_recherche",
       colonne_code_postal="code_postal",   # au lieu de colonne_code_insee="code_insee"
   )
   ```
2. **Normaliser le CP à 5 chiffres** avant l'appel : l'API AC envoie le CP
   **sans zéro initial** (`1110` au lieu de `01110`) ; sans lpad, le filtre
   postcode de BAN ne matchera pas. `df_chunk["code_postal"] = df_chunk["code_postal"].str.zfill(5)`
   (uniquement si numérique).
3. **Supprimer `_derive_code_insee_batch`** (def ~l.76-131) **et son appel**
   (~l.225-250) : son unique rôle était d'alimenter le filtre `citycode`, devenu
   inutile.
4. **Dérivation `departement`** (~l.283-292) : ne plus prioriser
   `code_insee[:2]` (peut être pollué) → baser sur `code_postal[:2]` (ou
   `code_insee_geocode` BAN une fois le géocodage fait).
5. Vérifier la **consolidation post-géocodage** (~l.274-302) : `nom_commune`,
   `code_insee`, `code_postal` doivent désormais provenir du **résultat BAN**
   (`*_geocode`/`*_ban`), pas de la source AC, en priorité.

## Validation après implémentation
- Outil : `scripts/verifier_adresse_canonique_sirene.py` (déjà en place).
  ```bash
  DATABASE_URL=postgresql://dataspace:dataspace_dev_password@localhost:5532/dataspace_dev \
  SIRENE_API_KEY=<clé> python3 scripts/verifier_adresse_canonique_sirene.py -o ecarts.csv --csv-tout
  ```
  Attendu : la part AC `COMMUNE_DIFFERENTE` chute fortement ; conformité AC ↑.
- Env : `python3` système (a pandas/psycopg2/etl), `dataspace_dev` port 5532
  (creds dans `docker-compose.dev.yml`).

## Hors scope de ce fix (étapes suivantes)
- **Backfill SIRENE** de l'existant (le fix d'ingestion n'agit que sur les
  prochains runs ; les ~1 189 canoniques déjà fausses restent à corriger).
- Les **128 cas inter-départements siège≠site** : pas des bugs de géocodage ;
  décider backfill SIRENE vs reclassement en **antenne** séparément.
- Côté AC : leur signaler les 3 défauts source (placeholder `57490`,
  `city_insee_code` ≠ `zipcode`, CP sans zéro) — CSV
  `ac_incoherence_code_insee_interdept.csv`.
