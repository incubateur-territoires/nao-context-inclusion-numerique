# Enrichissement et précédence des données d'adresse

> Doc en construction — phase 0 du chantier "précédence adresse SIRENE/BAN".
> Sections 1-3, 6-9 : audit de l'existant. Sections 4-5 : règles à figer pendant l'implémentation.
> MAJ 2026-06-12 : aligné sur la refonte SA + LI (`860b40c`, éclatement de
> `main.structure` en `main.structure_administrative` + `main.lieu_inclusion`)
> et sur la nouvelle stratégie de géocodage AC (filtre CP, plus de dérivation
> code_insee).

## 1. Contexte

L'entrepôt sonum ingère des structures depuis plusieurs sources hétérogènes
(Coop, Cartographie nationale via mednum-cli, Aidants Connect, Conseiller
Numérique). Chaque source apporte tout ou partie des informations d'adresse,
et chaque pipeline les enrichit avec deux APIs externes :

- **SIRENE / API INSEE** : à partir d'un SIRET, retourne entre autres
  `denomination`, `etat_administratif`, et **une adresse postale**.
- **BAN / Géoplateforme IGN** : à partir d'une adresse texte, retourne
  `clef_interop`, `code_ban`, coords, codes INSEE/postal normalisés, score.

Comme les deux APIs renvoient une adresse, des **divergences** apparaissent :
- L'adresse SIRENE est l'adresse administrative de l'établissement (souvent
  le siège social, parfois un autre établissement de l'unité légale).
- L'adresse fournie par la source est l'adresse **physique** où la
  structure exerce son activité.

Aucune règle d'arbitrage explicite n'est codée aujourd'hui : selon le DAG,
soit on écrase, soit on garde les deux dans des colonnes parallèles, soit
on suit l'adresse BAN sans contrôle. Ce document trace ce qui existe et
fixe la règle attendue.

## 2. Sémantique des sources

| Source | DAG | Nature | Vérité | SIRET requis |
|---|---|---|---|---|
| Cartographie nationale | `carto-dag-import.py` | **Lieu** d'accueil | Adresse | Non |
| Coop | `coop-dag.py` | Employeur | SIRET | Non bloquant en pratique |
| Aidants Connect | `aidants-connect-dag.py` | Employeur | SIRET | Oui |
| Conseiller Numérique | (DAG postes/contrats) | Employeur | SIRET | Oui |

La carto agrège ~45 sources (hubs territoriaux, plateformes nationales,
conseils départementaux) via `mednum-cli`. **Toutes** sont traitées
sémantiquement comme "lieu" : c'est la vocation de la cartographie nationale
(répertorier les lieux d'accueil au public).

> **Conséquence** : pour les sources "lieu", l'adresse de la source prime
> sur l'adresse SIRENE. Pour les sources "employeur", c'est l'inverse —
> l'adresse est dérivée du SIRET via SIRENE puis géocodée par BAN.

## 3. Pipeline d'enrichissement actuel

### 3.1 SireneBatch — `etl/sirene_batch.py`

À partir d'un SIRET valide (14 chiffres, ≠ `00000000000000`), interroge
l'endpoint `/siret` de l'API INSEE en POST batch (1000 SIRET max par
requête, 30 req/min).

**Colonnes produites** :
- `etat_administratif` (`Entreprise active / Etablissement actif`, ...)
- `code_activite_principale`, `categorie_juridique`, `denomination_sirene`
- `adresse_sirene` — concaténation `numero + indice_rep + type_voie + libelle_voie`
  (texte libre, **non banifié**)
- `code_insee_sirene`, `code_postal_sirene`
- `date_creation_sirene`, `tranche_effectifs_sirene`
- `sirene_trouve` (booléen)

⚠️ `adresse_sirene` est une chaîne brute. Pas de `clef_interop_ban` ni
de coords. Pour comparer avec l'adresse source banifiée, il faut la
faire passer par `GeocodeurBatch` — **pas fait aujourd'hui**.

### 3.2 GeocodeurBatch — `etl/geocoding_batch.py`

À partir d'une adresse texte (et idéalement `code_postal` + `code_insee`),
interroge `/search/csv` de la Géoplateforme IGN (50 req/s, 200k lignes max
par requête synchrone).

**Colonnes produites** :
- `code_insee_geocode`, `code_postal_geocode`, `nom_commune`, `nom_voie`,
  `numero_voie`
- `longitude`, `latitude`, `geom` (WKT `POINT(...)`)
- `score_geocodage` (0-1), `geocodage_valide` (= score ≥ 0.5, configurable)
- `clef_interop` (= `result_id`), `code_ban` (= `result_banid`, UUID)
- `label_geocodage`

**Garde-fou critique** (l. 320-356) : si `code_insee` envoyé et
`result_citycode` retourné diffèrent, le résultat est **annulé**
(toutes colonnes à NULL). Évite les homonymes hors commune.

### 3.3 `etl/structure_enrichment.py` — orchestration

Trois modes selon le `data_type` :

#### Mode "base" — `_process_base_data_batch`
SIRENE puis BAN. **Les colonnes BAN écrasent l'adresse source**
(`code_postal`, `code_insee`, `nom_commune`, `nom_voie`, `numero_voie`).
Utilisé hors carto. Pas de garde adresse divergente.

#### Mode "carto" — `_process_carto_data_batch`
SIRENE (via colonne `pivot` = SIRET de carto) puis BAN, mais les colonnes
BAN sont **préfixées `ban_*`** (`ban_clef_interop`, `ban_code_ban`,
`ban_voie`, `ban_ville`, `ban_code_insee`, ...). Les deux versions
coexistent dans `import.carto` :
- adresse **mednum-cli** (déjà géocodée par BAN en amont) → colonnes brutes
- adresse **SIRENE banifiée par sonum** → colonnes `ban_*`

**Retry BAN sans code_insee** (commit `44e159f`) : activé uniquement
si mednum-cli n'a pas fourni de coords. Sinon on garde la coord
mednum (qui passe par le 1er INSERT de `integration_adresses`).

#### Mode legacy ligne par ligne — autres data_types
`process_siret_data` → `process_base_data` / `process_carto_data` /
`process_structure_data`. Conserve `_enrich_with_ban` qui skip si
`clef_interop` ou `ban_clef_interop` déjà présent.

### 3.4 Intégration dans le modèle SA + LI (ex `main.structure`)

Depuis la refonte `860b40c`, `main.structure` est **deprecated**
(commentaires SQL posés par `35e25b5`). Le modèle cible :
- `main.structure_administrative` (SA) — identité légale : `siret`,
  `denomination_sirene`, `etat_administratif`, `adresse_id`,
  `last_sirene_enrich_at`, contrainte UNIQUE `(siret, denomination_antenne)`.
- `main.lieu_inclusion` (LI) — lieu d'accueil : `adresse_id`, `nom`,
  `structure_coop_id` (UNIQUE), `structure_cartographie_nationale_id`,
  `visible_pour_cartographie_nationale`, `source`, `edited_by`.

#### `coop-dag.py` — `structures_ingest` (l. 1024+)
- `main.adresse` : INSERT batch ON CONFLICT clé naturelle (l. 1148),
  depuis l'adresse BAN.
- SA : upsert ON CONFLICT `(structure_coop_id)`, ou ON CONFLICT
  `structure_administrative_siret_antenne_ukey` pour les nouveaux avec
  SIRET (l. 1405-1417).
- LI : INSERT ... ON CONFLICT `(structure_coop_id)` DO UPDATE (l. 1457).
- Skip enrichissement SIRENE si `last_sirene_enrich_at` < 4 mois, lu
  depuis SA (l. 288).

Pas de comparaison adresse SIRENE vs adresse source. La BAN écrase la
source dans le mode "base".

> NB : la MR `refactor/coop-dag-extract` (en attente de merge) déplace la
> logique métier vers `etl/load/coop.py` — pointeurs à rafraîchir après merge.

#### `carto-dag-import.py:231+` — `integration_lieux` (ex `integration_structures`)
Cible `main.lieu_inclusion`, via une table temp `_match` :
1. UPDATE par `carto_id` (= `structure_cartographie_nationale_id`) — cas nominal
2. UPDATE par `structure_coop_id` (le lieu existe via Coop, on lui attribue
   le `carto_id` pour la première fois)
3. INSERT nouveaux lieux (ni carto_id ni coop_id ne matchent ; warn JSONB
   `unknown_coop_id` si le coop_id reçu est inconnu en base)

Plus : transfert du coop_id si double match carto+coop sur deux lieux
différents, backfill `import.carto.lieu_inclusion_id`, désactivation des
lieux absents du nouvel import.

L'`adresse_id` est résolu via (l. 245-265) :
- 1er essai : `main.adresse.clef_interop = c.ban_clef_interop`
  (la BAN sur l'adresse mednum)
- Fallback (commit `44e159f`) : clé naturelle `(code_postal, nom_commune,
  nom_voie, numero_voie)` — pour rattraper les lignes insérées depuis
  les coords mednum quand le retry BAN était désactivé.

⚠️ Le SQL utilise `ban_clef_interop` (= adresse mednum banifiée) **PAS**
le résultat de la banification de l'adresse SIRENE. Aujourd'hui cette
deuxième information **n'existe pas**.

#### `aidants-connect-dag.py` — `_enrich_chunk_sirene_ban` (l. 118+)
La stratégie de `2474f9c` (dérivation `code_insee` via
`admin.insee_cp × admin.commune`) a été **remplacée** : le `city_insee_code`
d'AC est pollué (placeholder 57490/Moyenvic, désync avec city/zipcode).
Comportement actuel :
- Filtre BAN par **code_postal** (postcode), PAS par code_insee. CP
  normalisé à 5 chiffres (`_normalize_cp`, AC envoie `1110` pour `01110`).
  Cf `docs/fix-ingestion-ac-geocodage-cp.md` (A/B : conformité SIRENE 34→69 %).
- Suffixes explicites `(suffixes=("", "_ban"))` sur le merge BAN.
- Consolidation post-merge : `nom_commune` et `code_postal` priorité BAN,
  fallback source. Département dérivé de `code_insee_geocode` (gère 2A/2B).
- Path dégradé : si BAN échoue, INSERT depuis l'adresse source brute
  (sans geom) plutôt que de perdre le lien structure ↔ adresse.
- `last_sirene_enrich_at` lu/écrit sur SA (cutoff 4 mois, comme Coop).

## 4. Règles de précédence — Phase 0 (TODO)

À figer pendant l'implémentation. Vue d'ensemble pseudo-code :

```
adresse_source_banifiée = GeocodeurBatch(adresse_source, code_postal, code_insee)

si source.nature == "lieu" (carto et toutes ses sous-sources):
    # L'adresse de la source est la vérité.
    adresse_référence = adresse_source_banifiée

    si SIRET fourni:
        adresse_sirene = SireneBatch(SIRET).adresse_sirene
        adresse_sirene_banifiée = GeocodeurBatch(adresse_sirene)  # NEW

        si adresse_sirene_banifiée non disponible:
            # L'adresse SIRENE n'est pas géocodable → on ne peut pas comparer
            # → on supprime le SIRET (un SIRET non vérifiable est trompeur)
            siret = NULL
        sinon si même_adresse(adresse_référence, adresse_sirene_banifiée):
            # Adresses cohérentes → garder le SIRET
            garder SIRET
        sinon:
            # Adresses divergentes → SIRET probablement le siège social
            # ou un autre établissement → on supprime le SIRET
            siret = NULL

si source.nature == "employeur" (Coop, AC, CN):
    # Le SIRET est la vérité.
    SIRET requis.
    adresse_référence = GeocodeurBatch(SireneBatch(SIRET).adresse_sirene)
    # Pas de comparaison.
```

**À figer** :
- Que faire des champs SIRENE dérivés (`denomination_sirene`,
  `code_activite_principale`, ...) quand le SIRET est nullifié pour un
  lieu ? Garder (informatif) ou supprimer (cohérence) ?
- Marqueur de traçabilité : `siret_supprime_par_arbitrage` (boolean) ?
  Ou colonne `ban_match_status` (`match` / `divergent` /
  `sirene_unbanifiable` / `no_siret`) ?
- Lieu cible du code : Python (`structure_enrichment.py`) ou SQL
  (`integration_lieux`) ? Préférence Python pour testabilité.

## 5. Comparaison "même adresse" — Phase 0 (TODO)

À investiguer empiriquement. Plusieurs critères candidats, du plus
strict au plus tolérant :

1. **Strict** : `clef_interop_source == clef_interop_sirene`
2. **Tolérant code_insee** : `code_insee_source == code_insee_sirene`
3. **Composite** : `code_insee` égal **ET** fuzzy(`nom_voie`) > 0.85
   **ET** `numero_voie` identique
4. **Géo** : distance(coords_source, coords_sirene) < X mètres

**Étapes proposées** :
1. Sur le pipeline carto actuel, banifier systématiquement l'adresse
   SIRENE et stocker `ban_clef_interop_sirene`, `score_sirene` dans
   `import.carto` — sans encore arbitrer.
2. Mesurer sur l'échantillon réel : taux de SIRET nullifiés selon chaque
   critère. Inspecter les divergences.
3. Calibrer le seuil. Documenter la décision dans cette section.

## 6. Cas limites

| Cas | Fréquence | Comportement actuel |
|---|---|---|
| Pas de SIRET (lieu carto) | Courant | OK : SIRENE skippé, BAN seul. |
| SIRET non trouvé en SIRENE | Rare mais réel | `sirene_trouve = false`, colonnes SIRENE NULL. SIRET conservé en base. |
| Adresse source non-banifiable (score < 0.5 ou `code_insee` mismatch) | Visible (~615 cas mesurés sur carto, commit `18b4cf3`) | Pas de `clef_interop`, pas de coords. Fallback clé naturelle ou path dégradé AC. |
| Adresse SIRENE non-banifiable | À mesurer | **Cas non géré** aujourd'hui (pas de banification SIRENE). À gérer en Phase 0 : pour un lieu → nullifier SIRET. |
| AC `city_insee_code` absent ou pollué | Fréquent | Le code_insee source est ignoré : filtre BAN par CP normalisé (cf `docs/fix-ingestion-ac-geocodage-cp.md`). |
| Carto retry BAN après échec | Commit `44e159f` | Retry sans code_insee uniquement si mednum-cli n'a pas fourni de coords. |
| Structure visible carto sans adresse_id | 1374 cas corrigés (commit `18b4cf3`) | Bug ETL + retry BAN + re-géocodage rétroactif. |

## 7. Traçabilité

**Colonnes existantes** (post-refonte SA + LI) :
- `main.lieu_inclusion.source` (texte : `coop`, `carto`, ...) et
  `edited_by` (qui a écrit en dernier) — `edited_by` existe aussi sur SA
- `main.lieu_inclusion.import_warnings` (JSONB, ex. `unknown_coop_id`)
- `main.structure_administrative.last_sirene_enrich_at` (date du dernier
  enrichissement SIRENE, cutoff 4 mois pour skip)

**À ajouter en Phase 0** (proposition) :
- `import.carto.ban_clef_interop_sirene` — clef BAN de l'adresse SIRENE
- `import.carto.ban_match_status` (enum) — résultat de l'arbitrage
- Log + métrique du nombre de SIRET nullifiés par run

## 8. Pointeurs code

| Sujet | Fichier | Lignes |
|---|---|---|
| Banification (BAN batch) | `etl/geocoding_batch.py` | tout |
| Enrichissement SIRENE batch | `etl/sirene_batch.py` | tout |
| Garde mismatch INSEE BAN | `etl/geocoding_batch.py` | 320-356 |
| Orchestration mode base | `etl/structure_enrichment.py` | 298-424 |
| Orchestration mode carto | `etl/structure_enrichment.py` | 425-620 |
| Retry BAN sans code_insee carto | `etl/structure_enrichment.py` | 542-595 |
| Coop ingest structure (adresse + SA + LI) | `coop-dag.py` | 1024-1515 (`structures_ingest`) |
| Coop enrichissement SIRENE/BAN | `coop-dag.py` | 254-436 (`enrich_structures_batch`) |
| Carto integration_adresses | `carto-dag-import.py` | 147-230 |
| Carto integration_lieux | `carto-dag-import.py` | 231-405 |
| Adresse_id lookup carto | `carto-dag-import.py` | 245-265 |
| AC enrichissement SIRENE/BAN (filtre CP) | `aidants-connect-dag.py` | 118-290 (`_enrich_chunk_sirene_ban`) |

## 9. Historique des garde-fous (commits récents)

Chaque garde-fou existe à cause d'un bug réel mesuré. À lire avant de
toucher au pipeline d'enrichissement.

- **`2474f9c`** `fix(aidants-connect): éviter banification sans filtre code_insee`
  (2026-04-29). ~1000 structures AC déportées dans le mauvais département
  parce que BAN matchait des homonymes en l'absence de `code_insee`.
  → Dérivation `code_insee` via `admin.insee_cp × admin.commune`,
  consolidation `nom_commune` post-merge, fallback INSERT adresse brute.
  **Remplacé depuis** par le filtre BAN par CP normalisé (le code_insee AC
  s'est révélé pollué) — cf `docs/fix-ingestion-ac-geocodage-cp.md` et §3.4.

- **`44e159f`** `fix(carto): éviter retry BAN aveugle qui déporte les lieux`.
  ~512 lieux carto déportés (cas réel : `SIILAB_3183` Aisne → Deux-Sèvres)
  parce que le retry BAN sans `code_insee` matchait des homonymes
  (« Salle polyvalente », « Rue Jules Ferry »).
  → Retry désactivé sauf si mednum-cli n'a pas fourni de coords.
  Fallback adresse_id par clé naturelle dans `integration_lieux`
  (à l'époque `integration_structures`).

- **`3119e67`** `fix(carto): parse numero_voie et normalise codes postal/insee`.
  Normalisation des codes au niveau de l'extract.

- **`18b4cf3`** `fix(carto): corriger 1374 structures sans adresse dans la
  cartographie nationale`. Bug ETL où le CASE `adresse_id` court-circuitait
  l'update quand `siret IS NULL`. + retry BAN initial. + scripts ad hoc
  de re-géocodage rétroactif.

- **`42237be`** `Fix l: carto met des adresses_id à null` — itération
  précédente sur le même sujet.

## 10. À faire pour Phase 0

- [ ] Banifier systématiquement l'adresse SIRENE dans `_process_carto_data_batch`
  → produire `ban_clef_interop_sirene`, `score_sirene`, `code_insee_sirene_ban`.
- [ ] Mesurer sur run réel le taux de SIRET nullifiés selon plusieurs
  critères de comparaison (cf. section 5).
- [ ] Figer le critère "même adresse" — compléter section 5.
- [ ] Implémenter l'arbitrage en Python dans `structure_enrichment.py`
  (pas en SQL).
- [ ] Combiner avec le bug `geocodage_valide` non exploité (queue Adrien) :
  nullifier les colonnes `ban_*` quand `geocodage_valide == False`.
- [ ] Ajouter test de régression sur quelques cas typiques.
- [ ] Compléter sections 4, 5 et 7 de cette doc avec la règle figée.
