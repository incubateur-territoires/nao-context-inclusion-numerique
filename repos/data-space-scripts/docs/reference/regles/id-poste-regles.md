# id-poste — règles d'ingestion vers `main.structure`

Ce document décrit la sémantique du fichier source id-poste et la règle de consolidation appliquée par `schema-idPoste.py` lors de l'écriture dans `main.structure`.

## 1. Nature du fichier source

Le CSV id-poste est une **représentation tabulaire d'un modèle multidimensionnel** (poste × structure × personne × subvention …). En tabulaire :

- Une même structure apparaît sur **N lignes** du fichier — autant que de postes / personnes / sites qui s'y rattachent.
- Toutes les lignes qui partagent le même `structure_tp_id` portent **les mêmes valeurs** pour les attributs structure (`siret`, `nom`, `adresse`, `etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`).

→ Conséquence pratique : pour reconstituer la structure, on peut prendre **n'importe quelle** des lignes partageant un `structure_tp_id`. Aucune logique de priorité (siège, plus récent, plus complet) n'est nécessaire.

## 2. Règle d'unicité côté `main.structure`

`main.structure` est la **couche gold** : une ligne par structure unique inter-sources. La contrainte `structure_structure_tp_id_ukey UNIQUE (structure_tp_id)` (`database/migrations/V004_20250531__schema_main.sql:123`) est **légitime et voulue** :

| Couche | Table | `structure_tp_id` |
|---|---|---|
| Source | CSV id-poste | Peut se répéter sur plusieurs lignes (pattern tabulaire) |
| Bronze/Silver | `main.poste` | N'apparaît pas — la règle métier postes vit ici sur `(poste_conum_id, structure_id, personne_id)` |
| **Gold** | **`main.structure`** | **Unique — une seule ligne par tp_id** |

À ne pas confondre : `poste_ukey UNIQUE (poste_conum_id, structure_id, personne_id)` sur `main.poste` (V004:251) capture une règle différente — l'unicité d'une affectation poste × structure × personne. Elle ne dit rien sur le nombre de structures pouvant porter un même `structure_tp_id` côté gold (qui reste 1).

## 3. Règle de consolidation dans le DAG

`schema-idPoste.py` doit **dédupliquer par `structure_tp_id` avant** d'écrire dans `main.structure`, à la fois pour les INSERT et pour les UPDATE.

### INSERT (étape 4, déjà conforme)

À `schema-idPoste.py:949-962` : itération avec `seen_tp_ids = set()`, on garde la première occurrence de chaque tp_id puis on `INSERT … ON CONFLICT DO NOTHING`. Conforme.

### UPDATE (étape 3, à aligner)

À `schema-idPoste.py:903-919` : le code itère **toutes** les lignes du CSV sans dédup par tp_id. Comme le UPDATE matche les structures existantes par `(siret, LOWER(nom), adresse_id)` et que plusieurs lignes CSV portent le même tp_id avec ces attributs identiques, plusieurs lignes physiques `main.structure` peuvent recevoir la même affectation `structure_tp_id` → violation de `structure_structure_tp_id_ukey`.

Correctif : ajouter le même `seen_tp_ids` qu'à l'étape 4 :

```python
update_rows = []
seen_tp_ids = set()
for _, row in data.iterrows():
    tp_id = row.get("structure_tp_id")
    if tp_id in seen_tp_ids:
        continue
    adresse_id = _resolve_adresse_id(row)
    if not adresse_id:
        continue
    seen_tp_ids.add(tp_id)
    update_rows.append((
        tp_id,
        adresse_id,
        _fmt_structure(row.get("etat_administratif"), "etat_administratif"),
        _fmt_structure(row.get("code_activite_principale"), "code_activite_principale"),
        _fmt_structure(row.get("categorie_juridique"), "categorie_juridique"),
        _fmt_structure(row.get("denomination_sirene"), "denomination_sirene"),
        _fmt_structure(row.get("siret"), "siret"),
        row.get("nom"),
        adresse_id,
    ))
```

## 4. Cible unique par v-row + garde inter-run

> ⚠️ **Refonte 2026-05** : la cible est désormais `main.structure_administrative`
> (et non `main.structure`), dont l'identité est `(siret, denomination_antenne)`
> NULLS NOT DISTINCT — la colonne `nom` n'existe plus. Le match historique
> `LOWER(s.nom) = LOWER(v.match_nom)` n'est plus possible et a été retiré.

Deux problèmes distincts se cumulent :

- **Fan-out intra-requête** : plusieurs antennes peuvent partager `(siret, adresse_id)`
  avec `structure_tp_id IS NULL` (réseaux co-localisés type Département × Maisons,
  doublons de consolidation `V073`, antennes aidants-connect géocodées sur l'adresse
  du **siège** au lieu de leur commune). Un `WHERE` qui matche sur `(siret, adresse_id)`
  touche **toutes** ces lignes et tente de leur poser le **même** `structure_tp_id`
  → `UniqueViolation` *à l'intérieur du même UPDATE*. Le garde `NOT EXISTS` ne protège
  pas (il ne voit que le snapshot pré-requête).
- **Divergence inter-run** : si `main.structure_administrative` a déjà ce `structure_tp_id`
  posé sur une autre ligne (run précédent, donnée stale), reposer ce tp_id ailleurs viole
  aussi la contrainte.

L'`UPDATE` de l'étape 3 cible donc **au plus une ligne** par v-row, via une sous-requête
`s.id = (SELECT … LIMIT 1)`, et **scorée** : on rattache à l'antenne dont le nom ressemble
le plus au nom id-poste (`match_nom`, via `pg_trgm`), le siège (`denomination_antenne IS NULL`)
étant scoré sur `denomination_sirene`. Le garde `NOT EXISTS` couvre le cas inter-run :

```sql
WHERE s.id = (
        SELECT s3.id
        FROM main.structure_administrative s3
        WHERE s3.siret = v.match_siret
          AND s3.adresse_id IS NOT DISTINCT FROM v.match_adresse_id
          AND s3.structure_tp_id IS NULL
          AND s3.deleted_at IS NULL
        ORDER BY (CASE WHEN s3.denomination_antenne IS NULL
                       THEN similarity(lower(coalesce(s3.denomination_sirene, '')), lower(v.match_nom))
                       ELSE similarity(lower(s3.denomination_antenne), lower(v.match_nom)) END) DESC,
                 (s3.denomination_antenne IS NULL) DESC,   -- tiebreaker : siège
                 s3.id                                     -- tiebreaker stable
        LIMIT 1
    )
  AND NOT EXISTS (
      SELECT 1 FROM main.structure_administrative s2
      WHERE s2.structure_tp_id = v.new_tp_id
  );
```

Effet : une seule antenne (la mieux matchée) reçoit le tp_id ; les autres restent à
`tp_id=NULL`, le batch ne crashe pas. La divergence de fond (réseaux non réconciliés,
doublons `V073`, géocodage AC sur le siège) est à traiter **en amont**, pas à masquer.

L'étape 4 (INSERT) n'a pas besoin de garde explicite : `ON CONFLICT DO NOTHING` couvre
les contraintes d'unicité de `main.structure_administrative`.

## 5. Symptôme du bug avant correctif

```
duplicate key value violates unique constraint "structure_administrative_structure_tp_id_ukey"
DETAIL:  Key (structure_tp_id)=(<id>) already exists.
```

déclenché dans `process_enriched_structure`. Le batch UPDATE assignait le même
`structure_tp_id` à plusieurs antennes distinctes de `main.structure_administrative`
partageant `(siret, adresse_id)` (cf. fan-out §4).

## 6. Hypothèse implicite à éviter dans le code futur

`structure_tp_id` partage le **nom** mais **pas la sémantique source** des autres clés source de `main.structure` :

- `structure_coop_id`, `structure_ac_id`, `structure_cartographie_nationale_id` : la source elle-même garantit 1 identifiant ↔ 1 structure (l'API/source expose des entités déjà uniques).
- `structure_tp_id` : la source expose un format tabulaire où l'identifiant se répète. La déduplication est de la **responsabilité du DAG d'ingestion**, pas de la source.

Toute logique générique qui itère « pour chaque ligne du CSV id-poste, écrire dans `main.structure` » doit dédupliquer par `structure_tp_id` en premier.
