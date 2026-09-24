# Cartographie nationale (`carto-dag-import`)

> **Statut** : Sections 1 (vue d'ensemble + architecture), 2a (structures) et "Historique des fixes" couvertes. Sections 2b (personnes) et 2c (affectations) **non applicables** : la Cartographie nationale n'écrit ni dans `main.personne` ni dans `main.personne_affectations`. **À compléter** : Section 3 (réconciliation aval), Section 5 (pièges détaillés).
>
> **Questions métier ouvertes** : voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) (Q7-Q9, Q18).
>
> **Doc complémentaire** : `docs/ENRICHISSEMENT_ADRESSE.md` est en MR (branche `fix/precedence-adresse-sirene-ban`) et couvre le pipeline d'enrichissement adresse SIRENE+BAN. À croiser quand mergée.

## Vue d'ensemble

Le DAG `carto-dag-import` ingère les données de la **cartographie nationale de la médiation numérique**, agrégées par l'outil [`mednum-cli`](https://github.com/anct-cartographie-nationale/mednum-cli) (Node.js) à partir de multiples sources tierces (Hinaura, Fredo, Paca, Paris, etc.). Le DAG clone mednum-cli, lance ses transformers, fusionne et déduplique, enrichit (SIRENE + BAN), puis charge dans `import.carto` et bascule dans `main.structure` / `main.adresse`. Déclenche en fin la réconciliation des structures.

## Architecture du pipeline

```
[github.com/anct-cartographie-nationale/mednum-cli]
        │
init_working_dir (rm -rf + mkdir + git clone + npm install + .env)
        │
        ▼
[npm run transformer.*]  (lecture dynamique de package.json)
        │
        ▼ assets/output/*.csv (par source : Hinaura, Fredo, Paca, Paris…)
merge_files → merged_output.csv
        │
        ▼
split_files (par département) → assets/deduplicated/code_insee_*/*.csv
        │
        ▼
build_enrich_commands → run_enrich_batch (SIRENE via API_SIRENE_TOKEN + BAN)
        │
        ▼ *-geocoded-sirene.csv
run_deduplicate_command → *-lieux-de-mediation-numeriques-national-sans-doublons.csv
        │
        ▼
truncate_import_before (TRUNCATE import.carto)
        │
load_data_to_db → import.carto
   (rejette id > 2000 octets UTF-8 ; sépare ban_numero "33bis" → (33, "bis"))
        │
integration_adresses → main.adresse
   (2 branches : BAN clef_interop vs fallback clé naturelle)
        │
delete_paca_paris_ids
   (désassocie Paca/Paris de carto_id ; visible_pour_cartographie_nationale=FALSE)
        │
integration_structures → main.structure
   (4 statements séquentiels : carto_id / structure_coop_id / siret+nom+adresse / INSERT
    + backfill import.carto.structure_id (FK)
    + désactive structures absentes du nouvel import)
        │
        ▼
drop_working_dir (rm -rf /tmp/tmp.4ger4ger8)
```

## Schedule et déclenchement

- **Schedule** : `None` — déclenché par `ci-cd-carto-dag-import` (cron quotidien `0 1 * * *`).
- **Timeout** : 800 minutes (~13h).
- **Catchup** : False. **Max active runs** : 1.
- **Retries** : 3, backoff exponentiel (5 min → 60 min).

## Auth et configuration

| Élément | Valeur / Variable |
|---|---|
| `db_conn_id` | param enum (défaut `sonum-prod-db`) |
| `working_dir` | param `/tmp/tmp.4ger4ger8` (statique — note "à améliorer") |
| `repo_url` | param `https://github.com/anct-cartographie-nationale/mednum-cli.git` |
| `coop_api_token` | Variable Airflow — pipeline coop |
| `MATTERMOST_*` | Variables — notifs |

## Param `freeze` ou équivalent

**Non applicable.** Le pipeline est conçu pour être **entièrement rejoué** : chaque run recharge `import.carto` (TRUNCATE), puis recalcule les correspondances dans `main.structure`.

## Règles métier explicites importantes

1. **4 statements d'intégration des structures séquentiels en transaction** (et non CTE multi-branche — fix `ff3d1c6` pour éviter les `UniqueViolation` de snapshot CTE).
2. **Désassociation Paca/Paris à chaque run** (`delete_paca_paris_ids`, `carto-dag-import.py:619-635`). N'agit que sur les structures Paca/Paris **encore visibles avec `structure_cartographie_nationale_id`** (filtre `source IN ('Paca','Paris') AND visible_pour_cartographie_nationale IS TRUE AND structure_cartographie_nationale_id IS NOT NULL`) — pas un reset systématique. Raison métier à clarifier — voir Q8.
3. **Rejet des lignes avec id > 2000 octets UTF-8** (`load_to_postgresql.py:151-162`) — limite btree PostgreSQL (~2704 octets). Fix `0a77db0`.
4. **Retry BAN désactivé sauf si mednum-cli n'a pas de coords** (fix `44e159f`) — le retry naïf déportait ~512 lieux dans le mauvais département. Fallback `adresse_id` par clé naturelle.
5. **Backfill `import.carto.structure_id`** — FK ON DELETE SET NULL. Permet le diagnostic des rejets via `scripts/rapport_carto_integration.py`. Voir feat `a55c871` et Q7 (orphelinage temporaire).
6. **`visible_pour_cartographie_nationale = FALSE`** pour les structures absentes du nouvel import (`carto-dag-import.py:595-604`, dernier statement de `integration_structures` avant `COMMIT`). Match par `structure_cartographie_nationale_id` ↔ `import.carto.id`. Reset aussi `structure_cartographie_nationale_id = NULL`.

## Réconciliation aval

Trigger `TriggerDagRunOperator` → `structures-similarities-merge` (avec `reset_dag_run=True`). Pas de trigger personne (carto ne touche pas aux personnes ni à `main.personne_affectations`).

---

## Modèle de données — Structures

### Où chercher

| Étape | Référence code |
|---|---|
| Pipeline mednum-cli (clone + transformers + enrich + dédup) | `carto-dag-import.py:151-300` (orchestration des tâches `npm run *`) |
| Schéma `import.carto` | `etl/database_utils.py:9-57` (DTYPE_CARTO, 47 colonnes) |
| Load CSV → `import.carto` | `etl/load/load_to_postgresql.py:129-194` (`load_carto`, dont rejet `id > 2000 octets` lignes 151-162 et split `ban_numero "33bis"` lignes 172-179) |
| `integration_adresses` → `main.adresse` | `carto-dag-import.py` (recherche `integration_adresses`) — 2 INSERT séquentiels selon présence `ban_clef_interop` |
| `integration_structures` → `main.structure` | `carto-dag-import.py:414-608` — table temp `_match` + 5 statements séquentiels en transaction |
| Désassociation Paca/Paris | `carto-dag-import.py:619-635` (`delete_paca_paris_ids`) |
| Désactivation des absents | `carto-dag-import.py:595-604` (dans `integration_structures`, avant `COMMIT`) |
| Rapport diagnostic | `scripts/rapport_carto_integration.py` |

### Schéma cible — `main.structure`

Schéma commun aux 4 sources. Description complète et migrations : voir [`coop.md`](coop.md#schéma-cible--mainstructure).

Migrations spécifiques carto :
- V060 (FK `import.carto.structure_id` ON DELETE SET NULL — fix `a55c871`, traçabilité)
- V061 (vue API filtrée sur lieux actifs)
- V063 (vue API filtrée sur emploi actif)

### Comportement par champ — Carto sur `main.structure`

**Identité (`structure_cartographie_nationale_id`, `nom`, `siret`, `rna`)**
- INSERT : `structure_cartographie_nationale_id` ← `c.id` mednum-cli (rejet applicatif > 2000 octets UTF-8 — limite btree PostgreSQL ~2704). `nom` ← `c.nom`. `siret` parsé depuis `c.pivot` si match `^[0-9]{9,14}$` (rejet `'00000000000000'`). `rna` parsé depuis `c.pivot` si match `^W[0-9]{9}$`.
- UPDATE : `nom`, `siret` réécrits **avec garde `_CARTO_UKEY_GUARD`** — n'écrase que si `ukey_rn = 1` (premier intra-batch sur la clé naturelle) **et** aucune autre ligne en base ne porte déjà cette clé. `rna` réécrit sans garde. Pas de comparator temporel.
- Règle métier : la clé naturelle `(siret, nom, adresse_id)` est protégée — carto ne casse pas une clé naturelle existante en réécrivant un nom/siret qui créerait un doublon.

**Adresse (`adresse_id`)**
- INSERT/UPDATE : résolution en cascade par la table temp `_match` — priorité 1 = lookup `main.adresse.clef_interop = c.ban_clef_interop`, fallback = lookup par clé naturelle `(code_postal, nom_commune, nom_voie, COALESCE(numero_voie, 0), COALESCE(repetition, ''))` ; sinon NULL.
- En amont : `integration_adresses` insère 2 fois dans `main.adresse` (ON CONFLICT DO NOTHING) — branche A pour les lignes sans `ban_clef_interop` (coords mednum-cli + regex SQL sur `c.adresse`), branche B pour les lignes avec (colonnes `ban_*` enrichies par `npm run enrich`).
- Règle : pas d'orphelinage — pas d'INSERT sans `adresse_id` résolu (NULL accepté côté schéma mais utilisé pour signaler une structure sans géoloc, cf fix `18b4cf3`).
- ⚠️ **Divergence regex Python/SQL** sur le suffixe `numero_voie` (Python accepte `[a-zA-Z]`, SQL limité à `bis|ter|quater|quinquies`) — voir Q18.

**SIRENE (`etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`)**
- INSERT/UPDATE : depuis colonnes mednum-cli (qui appelle l'API INSEE en amont via `npm run enrich`).
- Règle : pas de COALESCE — carto écrase l'existant. Pas de cutoff (TRUNCATE + rejeu intégral à chaque run, donc `last_sirene_enrich_at` jamais alimenté côté carto). Q19 : faut-il harmoniser ?

**Catégories `TEXT[]` (11 colonnes)**
- INSERT/UPDATE : `string_to_array(c.<champ>, '|')` — toutes réécrites à chaque run.
- Champs : `typologies` (← `c.typologie` au singulier en source), `services`, `publics_specifiquement_adresses`, `prise_en_charge_specifique`, `frais_a_charge`, `dispositif_programmes_nationaux`, `formations_labels`, `autres_formations_labels`, `itinerance`, `modalites_acces`, `modalites_accompagnement`.
- Règle : carto est une source d'autorité sur les catégories métier (mednum-cli les normalise depuis les sources tierces). Pas de garde temporelle, écrasement systématique.

**Présentation et contact**
- `presentation_resume` (TEXT), `presentation_detail` (cast TEXT→JSONB), `horaires`, `prise_rdv` : INSERT/UPDATE depuis `c.<champ>`, écrasement systématique.
- `contact` (JSONB) : `jsonb_strip_nulls(jsonb_build_object('telephone', c.telephone, 'courriels', c.courriels, 'site_web', c.site_web))` — colonne **dépréciée V047** (Q14), carto continue d'écrire.
- `fiche_acces_libre` : ← `c.fiche_acces_libre` (VARCHAR). **Spécifique carto** — aucune autre source n'alimente ce champ.

**Visibilité (`visible_pour_cartographie_nationale`)**
- INSERT/UPDATE par les 5 statements de `integration_structures` : `TRUE`.
- UPDATE par `delete_paca_paris_ids` : `FALSE` + reset `structure_cartographie_nationale_id = NULL` pour les structures Paca/Paris encore visibles. **Q8 ouverte** sur la raison métier.
- UPDATE par la désactivation des absents (dernier statement avant `COMMIT`) : `FALSE` + reset `structure_cartographie_nationale_id = NULL` pour toute structure dont le `structure_cartographie_nationale_id` n'apparaît plus dans le nouvel `import.carto`.
- Règle métier : flag exclusif carto, reflète l'état "visible sur la cartographie publique nationale". Reset à chaque run pour les absents → réassociation au run suivant si la source réapparaît.

**`structure_coop_id` (adoption croisée)**
- Adoption conditionnelle selon la branche du matching (voir Stratégie de matching ci-dessous). Carto peut adopter le `structure_coop_id` Coop sur sa propre ligne (unification cross-source).

**Métadata**
- `source` : ← `c.source` mednum-cli (origine du lieu : `"Hinaura"`, `"Fredo"`, `"Paca"`, `"Paris"`, etc.). Différent du concept "source" pour `personne_affectations`.
- `edited_by = 'carto'` : force sur INSERT et UPDATE.
- `last_sirene_enrich_at` : non écrit (TRUNCATE + rejeu, pas de cutoff).

**Champs ignorés du schéma incoming**
- `date_maj` : présent dans DTYPE_CARTO mais non mappé vers `main.structure.updated_at` (qui est géré par le trigger V059).

**Champs cibles non touchés par carto**
- Identifiants externes : `structure_ac_id`, `structure_tp_id`.
- Champs propres à d'autres sources : `nb_mandats_ac` (AC), `publique` (idposte — Q16), `deleted_at`/`deleted_by` (AC), `mediateurs_en_activite`, `emplois` (Coop), `last_sirene_enrich_at` (cutoff Coop+AC).

### Stratégie de matching `main.structure` — comportement attendu

> ⚠️ **Section historique (structures, avant la refonte phase 4).** Le matching
> par clé naturelle (branche 3) et les gardes `_CARTO_UKEY_GUARD` /
> `_CARTO_COOP_GUARD` n'existent plus : seuls `carto_id` et `structure_coop_id`
> matchent. Depuis SEPT #1950 (sept. 2026), le SQL courant de la tâche
> `integration_lieux` vit dans `etl/load/carto_integration_lieux.py` et son
> comportement (état vs données, cycle de vie restreint aux lignes externes) est
> spécifié par `tests/carto/cas_cycle_de_vie_lieux.yml`. Le tableau ci-dessous
> décrit l'ancienne mécanique.

5 statements séquentiels en transaction (BEGIN/COMMIT). Pas de CTE multi-branche (fix `ff3d1c6` qui contournait le snapshot CTE). Table temp `_match` matérialisée au début, puis chaque statement voit l'état laissé par le précédent. Pour la mécanique exacte, lire `carto-dag-import.py:418-584`.

| Cas réel | Branche | Action |
|---|---|---|
| Cas rare : la structure existe en double — une ligne carto + une ligne coop avec un `structure_coop_id` divergent | **0b** (`:490-501`) | Fusion préalable : transfère le `structure_coop_id` sur la ligne carto, reset `NULL` sur la ligne coop concurrente |
| Structure déjà connue par `structure_cartographie_nationale_id` | **1** (`:504-509`) | UPDATE des champs carto + adoption optionnelle de `structure_coop_id` (via `_CARTO_COOP_GUARD` — n'adopte que si `coop_rn = 1` et libre) |
| Structure connue par `structure_coop_id` mais pas par carto_id | **2** (`:512-519`) | UPDATE des champs carto + adoption du `structure_cartographie_nationale_id` |
| Structure connue par clé naturelle `(siret, nom, adresse_id)` mais pas par les identifiants externes | **3** (`:521-531`) | UPDATE des champs carto + adoption du `structure_cartographie_nationale_id` **et** du `structure_coop_id` (via `_CARTO_COOP_GUARD`) |
| Aucun match | **4** (`:533-584`) | INSERT avec gardes inlinées dans le `WHERE` (`ukey_rn = 1`, `coop_rn = 1`, deux `NOT EXISTS` sur clé naturelle et `structure_coop_id`). ⚠️ N'utilise **pas** les constantes `_CARTO_UKEY_GUARD` / `_CARTO_COOP_GUARD` (réservées aux UPDATE) |

**Pourquoi la séquence statements vs CTE ?** Fix `ff3d1c6` (avril 2026) : les CTE data-modifying voyaient toutes le même snapshot initial, donc les gardes `NOT EXISTS` entre branches étaient inefficaces — UniqueViolation sur `structure_ukey`. Réécriture en transaction séquentielle pour que chaque statement voie l'état laissé par le précédent.

**Pourquoi la branche 0b ?** Sans cette fusion préalable, une structure créée par Coop puis identifiée par carto avec un `structure_coop_id` différent (par ex. mednum-cli a remonté un mauvais coop_id) génèrerait deux lignes orphelines. La branche 0b fusionne les références.

### Garde-fous historiques (structures)

| Hash | Date | Sujet |
|---|---|---|
| `44e159f` | 27/04 | Retry BAN aveugle déportait ~512 lieux dans le mauvais département (cas SIILAB_3183 : Aisne → Deux-Sèvres). Retry désormais activé **uniquement** si mednum-cli n'a pas fourni de coords. Fallback `adresse_id` par clé naturelle |
| `0a77db0` | 20/04 | Concat `__` du dedup mednum-cli produisait des id de plusieurs milliers d'octets → `UniqueViolation` sur `structure_cartographie_ukey`, tout le batch échouait. Rejet seuil 2000 octets + log count/max/noms |
| `3119e67` | 20/04 | Parse robuste adresse — `"21bis"` → `(21, "bis")` pour `smallint numero_voie` ; troncature `code_postal`/`code_insee` à 5 caractères (gère floats `"80220.0"`) |
| `18b4cf3` | 13/04 | 1 374 structures sans adresse réparées en 3 phases — CASE court-circuitant l'update si `siret IS NULL` (726 cas), retry BAN sans `code_insee` (615 cas), 36 doublons fantômes débloqués via similarities-merge |
| `ff3d1c6` | 13/04 | `UniqueViolation` sur `structure_ukey` depuis CTE multi-branche (snapshot partagé). Réécriture en requêtes séquentielles dans transaction `BEGIN/COMMIT` avec table temp `_match` matérialisée |
| `a55c871` | 13/04 | V060 `import.carto.structure_id` (FK ON DELETE SET NULL) — traçabilité des rejets, diagnostic via `rapport_carto_integration.py`. Q7 ouverte sur l'orphelinage temporaire après merge aval |

Liste exhaustive : [`../CHANGELOG.md`](../CHANGELOG.md).
