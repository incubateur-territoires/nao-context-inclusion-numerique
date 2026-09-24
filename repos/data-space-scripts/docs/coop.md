# Coop (`coop-import`)

> **Statut** : Sections 1 (vue d'ensemble + architecture), 1bis (périmètre API), 2a (structures), 2b (personnes), 2c (affectations) et "Historique des fixes" couvertes. Sections **à compléter** : Section 3 (réconciliation cross-source aval — `structures-similarities-merge`, `personne-similarities-merge`), Section 4 (modèle d'enrichissement Sirene+BAN — voir [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md) pour la version transverse), Section 5 (pièges détaillés). Section "activités" non couverte (peu de logique métier — un endpoint, ingest direct).
>
> **Questions métier ouvertes** : voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) (Q1-Q5, Q20-Q21).

## Vue d'ensemble

Coop (CoopNumérique) expose une API REST exposant trois ressources principales : **structures** (lieux d'activité), **utilisateurs** (médiateurs et coordinateurs) et **activités** (événements de médiation). Le DAG `coop-import` fetch structures et utilisateurs, enrichit côté BAN (géolocalisation), puis charge dans le schéma `main` avant de déclencher la réconciliation cross-source.

> **#1805 (V144)** : les **activités ne sont plus répliquées**. `main.activites_coop`
> est une **vue** sur `coop.activites` (même cluster Postgres, schéma Prisma de la
> coop) : temps réel, suppressions incluses (`suppression IS NULL`), plus de chemin
> ETL (`build_activites_endpoint`/`fetch_all_activites`/`transform_activites`/
> `ingest_activities` supprimés, silver `staging.coop__activites` droppé).
> Le diagramme ci-dessous ne montre plus que les branches restantes.

> **#1724 lot 2 / #1707 (V159, 2026-08-28)** : **plus d'import des structures par
> API.** La vue d'union `main.lieu_inclusion` (V153) lit `coop.lieu_inclusion` en
> direct ; le DAG ne maintient plus que l'**identité** des lieux dans
> `main.lieu_inclusion_registre` par un filet SQL direct sur le schéma `coop`
> (`etl/load/registre_lieux_coop.py` : INSERT des lieux vivants sans ligne, résolution
> d'adresse par `main.trouver_ou_creer_adresse_lieu` V155, rafraîchissement sur
> `modification`). Retirés : `fetch_all_structures`, `transform_structures`,
> `geocode_new_lieux`, `ingest_structures`, `build_role_index`, le param `freeze`,
> `source.coop__structures`, `source.coop__activites` (orpheline depuis V144),
> `staging.coop__structures`, le contrat `coop__structures`. Le fetch utilisateurs
> subsiste sans consommateur (retrait dans la MR suivante).
>
> **#1707 (V157, 2026-08-28)** : `insert_coordination_mediation` supprimée avec la
> table `main.coordination_mediation` (réplique de `coop.mediateurs_coordonnes`,
> unique consommateur `api.get_mediateur` lui aussi supprimé).

## Architecture du pipeline

```
[API /api/v1/utilisateurs]            [coop.lieu_inclusion — même cluster]
        │                                          │
fetch_all_utilisateurs                 reconcilier_registre_lieux
        │ (source.coop__utilisateurs)   (SQL direct : INSERT identité des lieux
transform_utilisateurs                  vivants sans ligne registre, adresse via
        │ (staging.coop__utilisateurs)  main.trouver_ou_creer_adresse_lieu,
   [sans consommateur]                  rafraîchissement sur `modification`)
                                                   │
                                     ┌─────────────┴─────────────┐
                                     ▼                           ▼
                           tests_main (dead-end)     trigger carto-cache-reset (prod)
```

## Schedule et déclenchement

- **Schedule propre** : `None`. Déclenché par `ci-cd-coop-import` (cron quotidien `0 8 * * *`) via la chaîne CI/CD : restore backup test → snapshot → run → verdict avec seuil → deploy prod si OK. Voir [`ci-cd-orchestrator.md`](ci-cd-orchestrator.md).
- **Déclenchement manuel** : via `ci-cd-orchestrator` ou directement `coop-import` en debug.
- **Timeout** : 15 heures (`dagrun_timeout=timedelta(minutes=900)`).

## Auth et configuration

| Élément | Valeur / Variable |
|---|---|
| Token API | `Variable.get("coop_api_token")` (Bearer) |
| Connexion Airflow API | `coop_api` |
| Connexion DB | param `db_conn_id` ∈ `sonum-test-db` / `sonum-dev-db` / `sonum-prod-db` |
| Working dir | `/tmp/tmp.coop` (drop en fin de run) |

## Param `freeze`

Supprimé en V159 (il ne figeait que la branche structures, disparue).

## Règle "coordinateurs sont médiateurs"

Tâche SQL `force_coordinators_to_mediators` après `ingest_utilisateurs` (`coop-dag.py:1584-1599`) :

```sql
UPDATE main.personne
SET is_mediateur = TRUE
WHERE is_coordinateur = TRUE AND is_mediateur = FALSE;
```

Raison métier à clarifier — voir `questions-metier-en-cours.md` Q1.

## Réconciliation aval

Le DAG ne fait pas la fusion cross-source. Il déclenche en bout de chaîne :
- `structures-similarities-merge` — fusion structures Coop / idposte / Aidants Connect / Carto.
- `personne-similarities-merge` — fusion personnes / médiateurs.

Règles de fusion partiellement documentées dans [`CONTACT_MERGE.md`](CONTACT_MERGE.md).

---

## Périmètre API Coop

L'API Coop (`https://coop-numerique.anct.gouv.fr/api/v1/`) expose 7 endpoints, tous en GET (read-only). Le DAG en importe 3 :

| Endpoint | Importé ? | Note |
|---|---|---|
| `/api/v1/structures` | ✅ | |
| `/api/v1/utilisateurs` | ✅ | inclut les `lieu_activite` inline (cf Section 2 affectations) |
| `/api/v1/activites` | ❌ | plus importé depuis #1805 — `main.activites_coop` est une vue sur `coop.activites` (V144) |
| `/api/v1/lieux-activite` | ❌ | redondant — les lieux arrivent inline dans `utilisateurs` |
| `/api/v1/archives-v1/cras` | ❌ | voir Q2 |
| `/api/v1/statistiques` | ❌ | voir Q2 |
| `/api/v1/health`, `/api/v1/openapi`, `/api/v1/documentation` | ❌ | utilitaires (normal) |

## Affectations cross-source `main.personne_affectations`

Le DAG Coop pose deux types d'affectation, selon une règle métier importante (`http_airflow.py:687-713`) :

- **`type='lieu_activite'`** — toujours, depuis `attributes.mediateur.en_activite` de chaque utilisateur.
- **`type='structure_emploi'`** — uniquement si **`cn_pg_id IS NULL` OU `conseiller_numerique_id IS NULL`** côté incoming Coop (= utilisateur pas pleinement identifié comme CoNum). Sinon, c'est `schema-idPoste` qui pose `structure_emploi` avec `source='idposte'` → évite le doublon cross-source.

Tableau cross-source consolidé : voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) section "Notes pour doc transverse".

---

## Modèle de données — Structures

> **Format** : pour chaque champ ou groupe de champs, **comportement attendu** (INSERT / UPDATE / skip) + **règle métier** en français + pointeur code pour la mécanique exacte. La prose ne reproduit jamais les `CASE WHEN` du SQL — pour ça, lire le code (les revues répétées ont trop souvent fait dériver les paraphrases).

### Où chercher

| Étape | Référence code |
|---|---|
| Fetch + transform incoming | `etl/extract/connectors/http_airflow.py` (data_type=`coop_structures`) |
| Enrichissement SIRENE+BAN (cutoff 4 mois) | `coop-dag.py` `enrich_structures_batch` — cf [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md) |
| UPSERT principal | `coop-dag.py` `structures_ingest` — CTE 3 branches `up_by_coop` / `up_by_ukey` / `ins` |
| Re-push SIRENE post-enrichissement | `coop-dag.py` `enrich_structures_batch` § batch UPDATE (avec `last_sirene_enrich_at`) |
| Réconciliation aval | DAG `structures-similarities-merge` (partiel : [`CONTACT_MERGE.md`](CONTACT_MERGE.md)) |

### Schéma cible — `main.structure`

Schéma commun aux 4 sources. **Source de vérité** :
- [`database/data_dict.md`](../database/data_dict.md) (généré 2026-03-13 commit `27683c9`, fraîcheur Q17)
- [`database/MCD.svg`](../database/MCD.svg)
- Migrations `database/migrations/V*.sql` pour les évolutions post-mars 2026

Migrations qui touchent `main.structure` :
- V004 (CREATE), V025 (contraintes adresse), V026 (`edited_by`), V033 soft delete (`deleted_at`/`deleted_by`, aussi sur `main.personne`)
- V047 (`main.contact` + `main.contact_structure` séparées de `main.structure.contact` JSONB désormais déprécié — Q14)
- V059 (smart `updated_at` trigger — mitige les bumps cross-source ; fix complet via V064 et `d8ca7ab`)
- V060 (FK `import.carto.structure_id` ON DELETE SET NULL — cf doc carto), V061/V063 (vues API carto filtrées sur actifs)

### Identifiants externes par source

- `structure_coop_id` (UUID) — Coop
- `structure_ac_id` (UUID) — Aidants Connect
- `structure_tp_id` (INT) — schema-idPoste (TP = Tableau de Pilotage CoNum)
- `structure_cartographie_nationale_id` (VARCHAR ; rejet applicatif > 2 000 octets UTF-8, cf doc carto et `0a77db0`)

Index unique clé naturelle : `(siret, nom, COALESCE(adresse_id, 0))`. Marqueur source : `edited_by` ∈ `{'coop','id-poste','aidants-connect','carto'}`.

### Comportement par champ — Coop sur `main.structure`

**Identité (`siret`, `rna`, `nom`, `structure_coop_id`)**
- INSERT : depuis `attributes.*` après normalisation (strip + null si vide).
- UPDATE : jamais — `siret` et `nom` sont les composants de la clé naturelle de matching ; `structure_coop_id` est la clé du `up_by_coop`.
- Adoption croisée : la branche `up_by_ukey` **renseigne** le `structure_coop_id` (incoming Coop) sur une ligne en base créée par idposte qui n'en avait pas (cf "Stratégie de matching" ci-dessous).
- Règle : si l'identité change réellement (renommage, fusion d'établissements), on ne modifie pas la ligne existante — soit on en crée une nouvelle (clé naturelle différente), soit la réconciliation aval s'en charge.

**`adresse_id`**
- INSERT : résolution en cascade (lookup `clef_interop` → lookup `code_ban` → INSERT `main.adresse` ON CONFLICT clé naturelle → NULL si données insuffisantes).
- UPDATE : oui dans `up_by_coop` / `up_by_ukey` — sous la garde temporelle générique (cf "Stratégie temporelle").
- Règle : on suit le déménagement d'une structure mais on ne le force pas si la donnée incoming est plus ancienne que ce qui est en base.

**SIRENE (`etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`)**
- INSERT : depuis API INSEE batch, mappés tel quel.
- UPDATE : **pas** par les CTE `up_by_coop` / `up_by_ukey`. Mis à jour par le **batch UPDATE post-enrichissement** (`coop-dag.py` `enrich_structures_batch`, recherche `last_sirene_enrich_at = v.ts`), avec `COALESCE(incoming, existing)` — l'API INSEE peut renvoyer NULL sur un champ, on garde alors la valeur déjà en base.
- Cutoff fraîcheur : 4 mois (re-enrichir si dernier enrichissement > 4 mois). Détail dans [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md).
- Règle : la donnée légale d'autorité (INSEE) écrase la donnée Coop, mais pas avec NULL.

**Catégories métier `TEXT[]` updatées (`typologies`, `services`, `publics_specifiquement_adresses`, `dispositif_programmes_nationaux`, `modalites_accompagnement`)**
- INSERT : depuis `attributes.<même_nom>` via `_normalize_array` (gère list, JSON string, PG-array `"{a,b}"`, string seule).
- UPDATE : oui dans `up_by_coop` / `up_by_ukey`, sous garde temporelle `incoming_ts > COALESCE(s.updated_at, s.created_at)`.
- Règle : on ne régresse pas avec une donnée plus ancienne que ce qui est en base.

**Catégories `TEXT[]` insérées mais jamais updatées (`prise_en_charge_specifique`, `frais_a_charge`, `formations_labels`, `autres_formations_labels`, `itinerance`, `modalites_acces`)**
- INSERT : oui (mêmes règles de normalisation).
- UPDATE : jamais — absentes des SET de `up_by_coop` / `up_by_ukey`.
- Règle : asymétrie non explicitement documentée. **Q20 ouverte**.

**Présentation longue (`presentation_resume`, `presentation_detail`)**
- INSERT : depuis `attributes.*`, null si vide.
- UPDATE : oui dans `up_by_coop` / `up_by_ukey`, sous garde temporelle.
- Règle : même logique anti-régression que les catégories updatées.

**Présentation utile mais figée (`horaires`, `prise_rdv`)**
- INSERT : oui.
- UPDATE : jamais.
- Règle : asymétrie non explicitement documentée — `horaires` est exactement le type de donnée qui change (extension d'amplitude, fermeture estivale). **Q21 ouverte**.

**Compteurs**
- `mediateurs_en_activite` : INSERT oui, UPDATE jamais — **Q3 ouvert** (oubli ou décision ? autre source d'autorité prime ?).
- `emplois` : INSERT oui, UPDATE oui dans les deux CTE sous garde temporelle.

**Contact JSONB**
- INSERT : oui depuis `attributes.contact`.
- UPDATE : jamais via les CTE structure.
- Règle : colonne **dépréciée depuis V047** (migration vers `main.contact` + `main.contact_structure`). Coop continue d'écrire malgré la dépréciation — **Q14 ouverte**.

**Métadata source**
- `edited_by = 'coop'` : posé à chaque INSERT / UPDATE par Coop (force, sans CASE WHEN).
- `source = 'coop-numerique'` : INSERT depuis `attributes.source` si la valeur vaut `'coop-numerique'`, NULL sinon. Jamais updaté.
- `last_sirene_enrich_at` : posé par le batch UPDATE post-enrichissement (timestamp `now()` côté DAG).
- `incoming_ts` : pas écrit en base — utilisé uniquement comme comparator (= `attributes.modification` de l'API).
- `created_at`, `updated_at` : gérés par triggers V059, jamais écrits par le DAG.

**Champs cibles non touchés par Coop**
- Identifiants des autres sources : `structure_ac_id`, `structure_tp_id`, `structure_cartographie_nationale_id`.
- Champs propres à d'autres sources : `nb_mandats_ac` (AC), `visible_pour_cartographie_nationale` (Carto), `publique` (idposte — Q16), `fiche_acces_libre` (Carto — Q16).
- Soft delete côté structure (`deleted_at`, `deleted_by`) : écrit par AC uniquement (via `is_active_ac=FALSE`). Coop écrit `deleted_at`/`deleted_by` côté **personne**, pas côté structure.

### Stratégie de matching `main.structure` — comportement attendu

3 branches en cascade dans `structures_ingest` (CTE `WITH ... up_by_coop, up_by_ukey, ins`). Pour la condition exacte de chaque branche, lire `coop-dag.py` (recherche : `up_by_coop AS`).

| Cas réel | Branche déclenchée | Action |
|---|---|---|
| Cette structure existe déjà avec ce `structure_coop_id` | `up_by_coop` | UPDATE des champs Coop (sous garde temporelle) |
| La structure existe par clé naturelle (`siret + nom + adresse_id`) mais sans `structure_coop_id` (typiquement créée par idposte) | `up_by_ukey` | UPDATE des champs Coop **+ adoption du `structure_coop_id`** |
| Aucun match | `ins` | INSERT |

**Pourquoi `up_by_ukey` ?** Cas réel fréquent : une mairie a été créée d'abord par idposte (qui ne connaît pas l'UUID Coop), puis remontée plus tard via l'API Coop. Sans cette branche, on créerait un doublon avec deux identités légales identiques. L'adoption du `structure_coop_id` Coop sur la ligne idposte unifie. Voir Q4.

**Garde temporelle générique** : les UPDATE de `up_by_coop` / `up_by_ukey` n'écrasent un champ que si `incoming_ts > COALESCE(s.updated_at, s.created_at)`. Évite la régression. Note : `updated_at` est un timestamp **global** (toutes sources confondues) — un autre DAG qui a bumpé `updated_at` sans modif métier réelle peut faire skipper une MAJ Coop légitime. Le fix `d8ca7ab` (V064) introduit `updated_at_coop`/`updated_at_idposte` côté `main.personne` pour résoudre ça côté personne ; côté structure, la mitigation passe par V059 (smart trigger qui ne bumpe que sur changement réel).

### Coordinateurs forcés en médiateurs

Tâche SQL post-ingest `force_coordinators_to_mediators` (rechercher ce nom dans `coop-dag.py`) : passe `is_mediateur = TRUE` pour toute personne ayant `is_coordinateur = TRUE AND is_mediateur = FALSE`. **Q1 ouverte** : règle métier voulue (un coordinateur exerce de fait l'activité de médiation) ou palliatif d'un bug API ?

### Garde-fous historiques (structures)

| Hash | Date | Sujet |
|---|---|---|
| `bb06430` | 22/04 | Typologies corrompues `{"['MUNI']"}` — double normalisation arrays PG (Python list → repr → re-parse) ; le merge cross-source contaminait ensuite les doublons propres |
| `30f77fa` | 21/04 | Structures avec `id_pg` skippées par `transform_coop_structures` (réputées prises par idposte, mais idposte n'importe que les structures employant un CN). Communes-mères de médiateurs non-CN perdues + affectations `structure_emploi` perdues. Dédup désormais case-insensitive |

Garde-fous personnes : voir section Personnes ci-dessous. Liste exhaustive cross-source : [`../CHANGELOG.md`](../CHANGELOG.md).

---

## Modèle de données — Personnes

### Où chercher

| Étape | Référence code |
|---|---|
| Fetch + transform incoming | `etl/extract/connectors/http_airflow.py` (data_type=`coop_utilisateurs`) |
| UPSERT principal | `coop-dag.py` `utilisateurs_ingest` — staging + cascade 4 étapes (3 UPDATE + 1 INSERT) |
| Règle post-ingest | `coop-dag.py` tâche `force_coordinators_to_mediators` |

### Schéma cible — `main.personne`

Schéma commun aux 3 sources qui écrivent (Coop, schema-idPoste, Aidants Connect). Carto n'y touche pas. Source de vérité :
- [`database/data_dict.md`](../database/data_dict.md) (généré 2026-03-13, fraîcheur Q17)
- [`database/MCD.svg`](../database/MCD.svg)

Migrations qui touchent `main.personne` :
- V004 (CREATE — `coop_id`, `cn_pg_id`, `conseiller_numerique_id`, `aidant_connect_id` chacun UNIQUE, `is_mediateur`, `is_coordinateur`, `contact JSONB`, champs AC)
- V019 (DROP `structure_id` → bascule sur `main.personne_affectations`)
- V026 (`edited_by`), V033 soft delete (`deleted_at`/`deleted_by`)
- V043 (DROP `is_active_ac` → bascule sur `main.personne_affectations.est_active`)
- V057 (`is_referent_ac`), V058 (`updated_at_ac`)
- V062 (`is_visible BOOLEAN DEFAULT NULL`, fix `9d19646`)
- V064 (`updated_at_coop`/`updated_at_idposte`, fix `d8ca7ab`)

### Comportement par champ — Coop sur `main.personne`

**Identifiants externes (`coop_id`, `cn_pg_id`, `conseiller_numerique_id`)**
- INSERT : `coop_id` depuis `item.id` (UUID) ; `cn_pg_id` depuis `attributes.conseiller_numerique.id_pg` (entier) ; `conseiller_numerique_id` depuis `attributes.conseiller_numerique.id` (UUID).
- UPDATE : adoption conditionnelle via `_guard(field)` selon l'étape de matching (cf "Stratégie de matching"). Une étape qui matche par X peut **adopter** Y et Z si :
  - l'incoming a une valeur non-NULL pour Y/Z,
  - et p.Y/Z est NULL ou égal à l'incoming,
  - et aucune autre ligne en base ne porte déjà cette valeur (`NOT EXISTS`).
- Règle métier : on ne casse jamais une valeur déjà posée par une autre source (prudence). On adopte uniquement si la place est libre.

**Identité (`nom`, `prenom`)**
- INSERT : depuis `attributes.nom` / `attributes.prenom` après `normalize_nom` / `normalize_prenom` (strip + casse, null si vide).
- UPDATE : **réécrit systématiquement** (force, sans CASE WHEN) sur toute étape de matching qui passe la garde temporelle.
- Règle : Coop est source d'autorité sur le nom/prénom dès lors que la donnée incoming est plus récente.

**Rôles (`is_mediateur`, `is_coordinateur`)**
- INSERT : `is_mediateur = TRUE si attributes.mediateur.id présent` ; `is_coordinateur = TRUE si attributes.coordinateur.id présent`.
- UPDATE : réécrits systématiquement.
- Post-ingest : tâche SQL `force_coordinators_to_mediators` passe `is_mediateur = TRUE` pour toute ligne `is_coordinateur=TRUE AND is_mediateur=FALSE`.
- Règle métier : un coordinateur exerce de fait l'activité de médiation. **Q1 ouverte** : règle voulue ou palliatif d'un bug API ?

**Confidentialité (`is_visible`, V062)**
- INSERT : depuis `attributes.mediateur.is_visible` (BOOLEAN nullable). ⚠️ Lu sur `attributes.mediateur`, **pas** `attributes.is_visible` (fix `9d19646` après 24 835 personnes mal filtrées).
- UPDATE : `COALESCE(s.is_visible, p.is_visible)` — Coop peut poser FALSE si vide, mais **ne supprime jamais** une valeur déjà posée par une autre source.
- Règle métier : la confidentialité est cumulative — une fois posée, jamais effacée par absence dans un payload incoming.

**Contact JSONB (déprécié V047)**
- INSERT : `s.contact::jsonb` direct (depuis `build_contact(attributes)`).
- UPDATE : **merge JSONB** via `p.contact = COALESCE(p.contact, '{}') || COALESCE(s.contact::jsonb, '{}')` — préserve les clés posées par d'autres sources, ajoute / écrase les clés Coop.
- Règle : colonne dépréciée par V047 au profit de `main.contact` + `main.contact_structure`. Coop continue d'écrire — **Q14 ouverte**.

**Soft delete (`deleted_at`, `deleted_by`, V033)**
- Côté staging : `deleted_at_coop` (suffixe disambiguation) ← `parse_timestamp(attributes.suppression)`.
- INSERT : `deleted_at = s.deleted_at_coop` (peut être NULL) ; `deleted_by = ARRAY['coop']` si suppression set, NULL sinon.
- UPDATE :
  - `deleted_at` : "dernière date gagne" — n'écrase la date existante que si l'incoming est strictement plus récent.
  - `deleted_by` : append `'coop'` sans doublon (vérification `'coop' = ANY(deleted_by)` avant `array_append`).
- Règle métier : trace l'historique des sources ayant marqué la suppression. Un aidant peut être marqué supprimé par Coop **et** par AC à des dates différentes — les deux dates sont conservées dans deleted_by, la plus récente dans deleted_at.
- ⚠️ **Important** : Coop écrit deleted_at/deleted_by côté **personne**. AC écrit ces champs côté **structure** (pas personne — voir AC). idposte ne les écrit nulle part.

**Stratégie temporelle (`updated_at_coop`, V064)**
- INSERT : `updated_at_coop = parse_timestamp(attributes.modification)` (pas de fallback).
- UPDATE : posé systématiquement à la valeur incoming, sert ensuite de comparator pour les prochains runs.
- `created_at`, `updated_at` (timestamps globaux) : gérés par triggers V059, jamais écrits par le DAG.
- Règle métier : chaque source compare contre son propre horodatage. Évite les skip croisés quand un autre DAG bumpe `updated_at` global sans modif métier réelle (commentaire explicite dans `coop-dag.py`, recherche : "garde temporelle"). Fix `d8ca7ab` via V064.

**Métadata source**
- `edited_by = 'coop'` : posé sur INSERT et UPDATE (force).

**Champs cibles non touchés par Coop**
- AC seulement : `aidant_connect_id`, `is_referent_ac`, `formation_fne_ac`, `profession_ac`, `nb_accompagnements_ac`, `updated_at_ac`.
- idposte seulement : `updated_at_idposte`.

### Stratégie de matching `main.personne` — comportement attendu

Cascade 4 étapes dans `utilisateurs_ingest`. Chaque UPDATE pose `staging.matched = TRUE` sur les lignes traitées pour éviter le retraitement par les étapes suivantes. La dernière étape INSERT n'agit que sur `matched = FALSE`. Pour la condition exacte, lire `coop-dag.py` (recherche : `_set_common`, `_where_newer`, `_guard`).

| Cas réel | Étape déclenchée | Adoption croisée |
|---|---|---|
| La personne est déjà connue côté Coop (matche par `coop_id`) | 1 | adopte `cn_pg_id` et `conseiller_numerique_id` si libres |
| Pas connue côté Coop, mais déjà importée par idposte avec `cn_pg_id` | 2 | adopte `coop_id` et `conseiller_numerique_id` si libres |
| Pas connue par `coop_id` ni `cn_pg_id`, mais existe avec un `conseiller_numerique_id` | 3 | adopte `coop_id` et `cn_pg_id` si libres |
| Aucun match | 4 | INSERT (ON CONFLICT DO NOTHING — sécurité contre race avec étapes précédentes) |

**Garde temporelle (`_where_newer`)** : un UPDATE n'écrase l'existant que si `updated_at_coop incoming > updated_at_coop existant`, **OU** si `deleted_at_coop incoming` est plus récent que `deleted_at` existant. Évite la régression et permet une nouvelle suppression de prendre effet.

**Garde anti-conflit (`_guard`)** : pour chaque identifiant externe à adopter, vérifie que l'incoming est non-NULL, que la place est libre côté p, et que personne d'autre en base ne porte déjà cette valeur. Si conflit → garde l'existant (prudence).

**Pourquoi cette cascade ?** Une même personne peut apparaître d'abord côté idposte (avec `cn_pg_id`), puis côté Coop (avec `coop_id`). Sans cette cascade, on créerait deux lignes pour la même personne. La cascade unifie : on matche sur l'identifiant disponible, on adopte ceux qui se révèlent libres.

### Garde-fous historiques (personnes)

| Hash | Date | Sujet |
|---|---|---|
| `9d19646` | 21/04 | `is_visible` lu sur `attributes.is_visible` (toujours absent) au lieu de `attributes.mediateur.is_visible`. Filtre V062 inopérant — 24 835 personnes ayant désactivé leur visibilité côté Coop restaient publiques |
| `d8ca7ab` | 20/04 | V064 `updated_at_coop`/`updated_at_idposte`. Avant : idposte bumpait `updated_at` global sans modif métier réelle, Coop comparait contre `p.updated_at` et skippait des MAJ légitimes. Solution : chaque source compare contre son propre horodatage |

---

## Modèle de données — Affectations

### Où chercher

| Étape | Référence code |
|---|---|
| Construction côté incoming | `etl/extract/connectors/http_airflow.py` (data_type=`coop_utilisateurs`, recherche `personne_affectations_list`) |
| Lookup + UPSERT | `coop-dag.py` `insert_personne_affectations` |

### Schéma cible — `main.personne_affectations`

Schéma commun aux 3 sources (Coop, idposte, AC). Carto n'y touche pas.

Migrations à connaître :
- V014 (CREATE — `personne_id NOT NULL FK`, `structure_id` FK nullable, `structure_coop_id`, `mediateur_coop_id`, `type` CHECK `('structure_emploi','lieu_activite')`, `suppression` TIMESTAMP). DROP des tables historiques `main.personne_structures_emplois` et `main.personne_lieux_activites`.
- V019 (data-migration de `personne.structure_id` → `personne_affectations`, recrée vues `dataviz` impactées).
- V042 (ADD `source CHARACTER VARYING` CHECK `IN ('idposte','aidants-connect','coop')`).
- V043 (ADD `est_active BOOLEAN NOT NULL DEFAULT TRUE` = `suppression IS NULL` ; DROP `suppression`). Recrée 2 indices uniques :
  - `personne_affectations_unique_key (structure_id, personne_id, type, source)` — clé métier post-V043
  - `personne_affectations_ukey (structure_coop_id, mediateur_coop_id, type)` — clé alternative diagnostic Coop

Particularités schéma :
- `structure_id` est nullable côté schéma (V014 : `INTEGER DEFAULT NULL`), mais le DAG Coop **skippe** une affectation quand le lookup `structure_coop_id → structure.id` échoue (compteur `skipped_struct_not_in_base`). Donc en pratique pas de NULL inséré côté Coop ; idposte et AC sont symétriques.
- Pas de colonne `edited_by` ; le marqueur source est porté par la colonne `source` (V042).

### Construction côté incoming (Coop)

Pour chaque utilisateur Coop, le DAG construit une liste d'affectations selon ces règles métier :

- **`lieu_activite`** : toujours posé pour chaque entrée de `attributes.mediateur.en_activite` (= les lieux où le médiateur intervient effectivement). Champs source : `structure_coop_id` (UUID lieu), `mediateur_coop_id` (UUID utilisateur), `suppression` (TIMESTAMP ou NULL).

- **`structure_emploi`** : posé pour chaque entrée de `attributes.emplois`, **uniquement si l'utilisateur n'est pas pleinement identifié comme CoNum** (= `cn_pg_id IS NULL OR conseiller_numerique_id IS NULL`). Si CoNum complet, c'est `schema-idPoste` qui pose `structure_emploi` avec `source='idposte'`.

Règle métier : on évite le doublon sémantique côté CoNum officiels (idposte fait foi). Voir Q4. La clé d'unicité `(structure_id, personne_id, type, source)` permet de toute façon à plusieurs sources de coexister, donc l'asymétrie est une optimisation, pas une contrainte d'intégrité.

### Comportement par champ — Coop sur `main.personne_affectations`

**Identifiants résolus par lookup**
- `personne_id` : lookup `main.personne` par `coop_id`. Si pas trouvé → **skip toute la ligne** (compteur `skipped_no_personne`).
- `structure_id` : lookup `main.structure` par `structure_coop_id`. Si pas trouvé → **skip toute la ligne** (compteur `skipped_struct_not_in_base`, log d'échantillon de 20 cas).
- Skip aussi si l'incoming n'a pas de `structure_coop_id` (compteur `skipped_no_struct_coop_id`).
- Règle : pas d'orphelinage volontaire — pas d'insertion d'affectation sans personne ET structure résolues.

**Identifiants traçabilité**
- `structure_coop_id`, `mediateur_coop_id` : INSERT depuis incoming, UPDATE réécrits sur ON CONFLICT (préservés à valeur incoming).

**`type`, `source`**
- INSERT : `type ∈ {'structure_emploi','lieu_activite'}` selon construction incoming, `source = 'coop'` (constante).
- UPDATE : jamais — clés du `unique_key`.

**`est_active`**
- INSERT : `incoming.suppression IS NULL`.
- UPDATE : réécrit à chaque run (ON CONFLICT DO UPDATE SET est_active = EXCLUDED.est_active).
- Règle : reflète l'état courant côté Coop. Si une affectation passe en `suppression IS NOT NULL`, le run suivant la marque `est_active = FALSE`. Pas de mémoire historique côté affectations Coop (la trace est ailleurs : `deleted_at` côté `main.personne`).

**Déduplication intra-batch**
- Avant l'INSERT, dictionnaire Python clé `(structure_id, personne_id, type, source)`, dernière ligne gagne. Évite d'envoyer plusieurs lignes pour la même clé d'unicité.

### Stratégie de matching

Match unique par `(structure_id, personne_id, type, source)`. Pas de cascade — la clé d'unicité est l'unique vecteur de déduplication. ON CONFLICT DO UPDATE réécrit `est_active`, `structure_coop_id`, `mediateur_coop_id` à chaque run.

### Règles cross-source

Voir tableau consolidé dans [`questions-metier-en-cours.md`](questions-metier-en-cours.md) — section "Tableau cross-source `main.personne_affectations`".

Synthèse pour Coop : pose toujours `(coop, lieu_activite)` + `(coop, structure_emploi)` uniquement si CoNum incomplet. Cas extrême : une personne avec `coop_id` + (cn_pg_id et conseiller_numerique_id complets) + `aidant_connect_id` aura 3 lignes pour la même `(personne, structure)` : `(coop, lieu_activite)`, `(idposte, structure_emploi)`, `(aidants-connect, structure_emploi)`. Si l'un des deux identifiants CoNum est NULL, on monte à 4 lignes (Coop ajoute alors `(coop, structure_emploi)`).
