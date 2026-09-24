# Aidants Connect (`aidants-connect-import`)

> **Statut** : Sections 1 (vue d'ensemble + architecture), 2a (structures), 2b (personnes), 2c (affectations) et "Historique des fixes" couvertes. **À compléter** : Section 3 (réconciliation aval), Section 5 (pièges détaillés). Pipeline d'enrichissement adresse : voir doc transverse [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md).
>
> **Questions métier ouvertes** : voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) (Q10-Q13).

## Vue d'ensemble

Le DAG `aidants-connect-import` ingère depuis l'API Aidants Connect (dispositif national ANCT/Numérique de labellisation des aidants accompagnant les usagers dans leurs démarches numériques administratives) deux ressources : **organisations habilitées** et **aidants** (personnes labellisées). Les structures sont enrichies SIRENE + BAN avant insertion dans `main.structure` / `main.adresse` ; les aidants alimentent `main.personne` et leurs affectations `main.personne_affectations`. Déclenche les deux DAGs de réconciliation aval.

## Architecture du pipeline

```
[API Aidants Connect — aidantsconnect.beta.gouv.fr]
   │
   ├─► /api/DfHGbvUGCHQD/fne_organisations/  (full scan, paginé)
   │       │
   │   fetch_all_aidants_structures
   │       │
   │   enrich_structures_batch
   │   (SIRENE batch + BAN + dérivation code_insee depuis admin.insee_cp × admin.commune
   │    si l'API n'a pas fourni city_insee_code — pour éviter homonyme BAN national,
   │    fix 2474f9c)
   │       │
   │   ingest_structures (main.adresse → main.structure)
   │
   └─► /api/DfHGbvUGCHQD/fne_aidants/?updated_at__gte=...  (incrémental)
           │
       get_max_updated_at_ac (SQL: MAX(updated_at_ac) sur main.personne WHERE aidant_connect_id IS NOT NULL)
           │
       build_aidants_endpoint
           │
       fetch_all_aidants_personnes
           │
       ingest_utilisateurs (main.personne, edited_by='aidants-connect')
           │
       ingest_personne_affectations
       (main.personne_affectations, type='structure_emploi', source='aidants-connect')
```

## Schedule et déclenchement

- **Schedule propre** : `None` — déclenché par `ci-cd-aidants-connect-import` (cron quotidien `0 5 * * *`).
- **Timeout** : 120 minutes.
- **Retries** : 3, backoff exponentiel (initial 2 min).
- **Callbacks** : Mattermost succès/échec via `MattermostNotifier`.

## Auth et configuration

| Élément | Valeur / Variable |
|---|---|
| `db_conn_id` | param enum (défaut `sonum-prod-db`) |
| Working dir | aucun depuis le lot 2 caches (2026-07-30) — plus de CSV intermédiaire, l'état enrichi = silver ⋈ caches `staging.*__cache` |
| Connexion HTTP | `fne_aidants` (host `aidantsconnect.beta.gouv.fr:443`) |
| Token API | Variable `aidants_connect_api_token` (header `Authorization: Token ...`) |
| `API_SIRENE_TOKEN` | Variable — enrichissement SIRENE (à passer fail-fast plutôt que skip silencieux) |
| `MATTERMOST_*` | Variables — notifs |

## Param `freeze` ou équivalent

**Non applicable.**

## Stratégie d'extraction par ressource

- **Structures** (`/fne_organisations/`) : **full scan** à chaque run. Déduplique sur `structure_ac_id` (UUID).
- **Aidants** (`/fne_aidants/?updated_at__gte=...`) : **incrémental** depuis `MAX(updated_at_ac)` en base. Si aucun max → full fetch. Déduplique sur `aidant_connect_id` (entier).

## Règles métier explicites importantes

1. **Filtre code_insee obligatoire pour BAN** (fix `2474f9c`) : sans `code_insee`, BAN matche un homonyme arbitraire en France → adresse fausse. Si l'API n'a pas `city_insee_code`, dérivation depuis `(code_postal, nom_commune)` via `admin.insee_cp × admin.commune`.

2. **`personne_affectations` posées par ce DAG** : `type='structure_emploi'`, `source='aidants-connect'` (`etl/load/aidants_connect.py:629`). Cohabite avec les autres sources via la clé d'unicité `(structure_id, personne_id, type, source)`.

3. **Désactivation par `is_active_ac`** : si `is_active_ac = FALSE` côté API, on positionne `deleted_at = updated_at_ac` et `deleted_by` append `'aidants-connect'` côté `main.structure` (pas `main.personne` — `ingest_utilisateurs` ne touche pas à ces colonnes côté personne). Côté affectations : `est_active = is_active_ac`.

4. **Dispositif "France Services"** : si l'API expose `france_services_label`, on insère/append `dispositif_programmes_nationaux = ARRAY['France Services']` (append, pas replace, si plus récent).

5. **Filtre structures sans `nom`** : ignorées avant insertion.

6. **Marqueur source** : `edited_by='aidants-connect'`.

## Réconciliation aval

Plus aucune : les DAGs `structures-similarities-merge` et
`personne-similarities-merge` ont été décommissionnés (refonte 2026, cf
`refonte-structure-plan.md` N5) — la déduplication est portée par les
contraintes UNIQUE du nouveau modèle (`siret`, `structure_ac_id`, …).

---

## Modèle de données — Structures

### Où chercher

| Étape | Référence code |
|---|---|
| Extract | `aidants-connect-dag.py` `fetch_all_aidants_structures` (GET `/fne_organisations/`, full scan paginé) |
| Dérivation `code_insee` (fix homonyme BAN) | `aidants-connect-dag.py:74-129` (lookup `admin.insee_cp × admin.commune` quand `city_insee_code` absent) |
| Enrichissement SIRENE+BAN | `etl/load/aidants_connect.py` `enrich_structures_batch` (cutoff 4 mois — cf [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md)) |
| INSERT batch | `etl/load/aidants_connect.py:393-449` (ON CONFLICT DO NOTHING — sans target) |
| UPDATE CTE fallback | `etl/load/aidants_connect.py:472-559` (pour les conflits par clé naturelle) |

### Schéma cible — `main.structure`

Schéma commun aux 4 sources. Description complète et migrations : voir [`coop.md`](coop.md#schéma-cible--mainstructure).

### Comportement par champ — Aidants Connect sur `main.structure`

**Identité (`structure_ac_id`, `nom`, `siret`)**
- INSERT : `structure_ac_id` ← `org.uuid` (UUID), `nom` ← `org.name` (structures sans nom **filtrées avant insertion**), `siret` ← `org.siret` validé via `validate_pivot()` (CHECK base `^\d{14}$`).
- UPDATE (CTE fallback) : `nom` réécrit sous garde temporelle. `siret` jamais touché. `structure_ac_id` adopté via `COALESCE(s.structure_ac_id, inc.structure_ac_id)` — préserve la valeur existante si déjà set sur la ligne matchée.
- Règle métier : on ne crée pas de structure sans nom ; on adopte l'identifiant AC sur une structure créée par une autre source pour unifier (voir Stratégie de matching).

**Adresse (`adresse_id`)**
- INSERT : résolution en cascade — lookup `clef_interop` → lookup `code_ban` → INSERT `main.adresse` (path nominal avec géolocalisation BAN, ou path dégradé sans géoloc si BAN a échoué) → NULL si données insuffisantes.
- UPDATE (CTE fallback) : `adresse_id` jamais touché.
- Règle métier : on préserve le lien structure ↔ adresse même quand BAN échoue (path dégradé : adresse texte sans géom). Pour la précédence SIRENE/BAN, voir `ENRICHISSEMENT_ADRESSE.md` (MR en cours).

**SIRENE (`etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`)**
- INSERT : depuis SireneBatch (lookup par siret).
- UPDATE (CTE fallback) : réécrits sous garde temporelle.
- Règle : pas de `COALESCE` ici (contrairement à Coop) — l'API SIRENE est traitée comme source d'autorité, on écrase l'existant si la garde temporelle passe.

**Spécifique AC (`nb_mandats_ac`)**
- INSERT : `org.num_mandats` (INTEGER).
- UPDATE (CTE fallback) : réécrit sous garde temporelle.
- Règle : champ exclusif à AC — aucune autre source ne l'alimente.

**`dispositif_programmes_nationaux` (TEXT[])**
- INSERT : `['France Services']` si `org.france_services_label`, NULL sinon.
- UPDATE (CTE fallback) : **append** `'France Services'` si présent côté incoming **et absent** côté existant. Jamais replace — préserve les autres labels posés par d'autres sources.
- Règle métier : un labellisé France Services le reste, même si une autre source ne pose pas ce label. Le label est cumulatif cross-source.

**Soft delete (`deleted_at`, `deleted_by`, V033)**
- INSERT : si `is_active_ac = FALSE`, `deleted_at = updated_at_ac` et `deleted_by = ARRAY['aidants-connect']`. Sinon NULL/NULL.
- UPDATE (CTE fallback) :
  - `deleted_at` : posé à `incoming_ts` si `is_active_ac = FALSE` ET `incoming_ts >= COALESCE(s.deleted_at, incoming_ts)` (n'écrase pas une date plus récente).
  - `deleted_by` : append `'aidants-connect'` sans doublon si `is_active_ac = FALSE`.
- Règle métier : trace cumulative — plusieurs sources peuvent marquer la suppression. Q13 ouverte : faut-il préférer `now()` côté Airflow plutôt que `updated_at_ac` côté API pour le timestamp ?
- ⚠️ **Important** : ces colonnes existent aussi sur `main.personne`, mais AC les laisse intactes côté personne — la désactivation passe par `est_active` côté affectations (post-V043, voir Section Affectations).

**Catégories TEXT[] et présentation (non alimentées)**
- INSERT : non incluses dans la col list de l'INSERT batch (`etl/load/aidants_connect.py:427-435`).
- UPDATE : non incluses dans le SET du CTE fallback.
- Règle : AC ne fournit pas ces données — viennent de Coop ou Carto. Si on observe ces champs vides sur une structure, c'est qu'aucune autre source ne l'a remontée.

**Métadata**
- `edited_by = 'aidants-connect'` : posé sur INSERT et UPDATE (force).
- `last_sirene_enrich_at` : actualisé après enrichissement réussi (cutoff 4 mois pour décider de re-enrichir).
- `incoming_ts` (= `org.updated_at`) : pas écrit en base — comparator pour le matching.
- `created_at`, `updated_at` : gérés par triggers V059, jamais écrits par le DAG.

**Champs cibles non touchés par AC**
- Identifiants externes : `structure_coop_id`, `structure_tp_id`, `structure_cartographie_nationale_id`.
- Champs propres à d'autres sources : `visible_pour_cartographie_nationale`, `fiche_acces_libre` (Carto), `mediateurs_en_activite`, `emplois` (Coop), `publique` (idposte — Q16).

### Stratégie de matching `main.structure` — comportement attendu

L'INSERT batch tente d'abord ; les structures qui conflictent passent dans la CTE fallback. Détail : `etl/load/aidants_connect.py:393-559`.

| Cas réel | Étape | Action |
|---|---|---|
| Nouvelle structure (aucun match `structure_ac_id` ni clé naturelle) | INSERT batch (`:425-438`) | INSERT direct |
| Structure déjà connue côté AC (`structure_ac_id` déjà en base) | INSERT batch ON CONFLICT DO NOTHING | Pas de modification — l'INSERT passe en `conflicted` puis CTE fallback |
| Structure déjà connue par clé naturelle `(siret, nom, adresse_id)` mais sans `structure_ac_id` (typiquement créée par Coop ou idposte) | INSERT batch ON CONFLICT DO NOTHING (conflit sur la clé naturelle) → CTE fallback (`:472-559`) | UPDATE des champs AC + adoption du `structure_ac_id` via `COALESCE` |

**Garde temporelle** : la CTE fallback n'UPDATE que si `incoming_ts >= COALESCE(s.updated_at, s.created_at)` **OU** `is_active_ac = FALSE` (avec garde supplémentaire sur `deleted_at`). Évite la régression mais permet une nouvelle suppression de prendre effet même si la donnée est par ailleurs identique.

**Pourquoi le CTE fallback ?** Symétrique à Coop / schema-idPoste. Une structure peut être créée d'abord par une autre source (sans `structure_ac_id`), puis remontée par AC. La CTE rattrape les conflits par clé naturelle et adopte l'`structure_ac_id` AC sur la ligne existante → unification cross-source. Validé par Adrien : "chaque source gère à sa façon".

### Garde-fous historiques (structures)

| Hash | Date | Sujet |
|---|---|---|
| `2474f9c` | 29/04 | BAN matche un homonyme arbitraire sans `code_insee` (~1 000 structures déportées dans le mauvais département). Fix : dérivation `code_insee` depuis `(code_postal, nom_commune)` via `admin.insee_cp × admin.commune` **avant** l'appel BAN (`aidants-connect-dag.py:74-129`). Pattern symétrique côté Carto (`44e159f`, ~512 lieux). Commentaire en clair dans le code : "Sans code_insee, le filtre du géocodeur BAN ne s'applique pas et BAN matche un homonyme n'importe où en France" |

---

## Modèle de données — Personnes

### Où chercher

| Étape | Référence code |
|---|---|
| Extract incrémental | `aidants-connect-dag.py` `fetch_all_aidants_personnes` (GET `/fne_aidants/?updated_at__gte=<MAX(updated_at_ac)>`) |
| UPSERT principal | `etl/load/aidants_connect.py` `ingest_utilisateurs` (staging + 1 UPDATE + 1 INSERT) |

### Schéma cible — `main.personne`

Schéma commun aux 3 sources qui écrivent. Description complète et migrations : voir [`coop.md`](coop.md#schéma-cible--mainpersonne).

### Comportement par champ — AC sur `main.personne`

**Identifiant externe (`aidant_connect_id`, INTEGER UNIQUE)**
- INSERT : depuis `payload.aidant_connect_id`. Clé de matching.
- UPDATE : jamais — clé du `ON CONFLICT`.
- Règle : pas de cascade comme Coop — AC n'a qu'un identifiant à matcher, donc match simple sur `aidant_connect_id`.

**Identité (`nom`, `prenom`)**
- INSERT : depuis payload AC (normalisations `http_airflow.py` à confirmer).
- UPDATE : sous garde temporelle `s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01')` — protection double (clause WHERE de l'UPDATE + CASE WHEN sur chaque champ).
- Règle métier : AC peut écraser nom/prenom posés par Coop ou idposte si la donnée incoming est plus récente.

**Spécifique AC (`formation_fne_ac`, `profession_ac`, `nb_accompagnements_ac`, `is_referent_ac`)**
- INSERT : depuis payload AC. `is_referent_ac` : `COALESCE(s.is_referent_ac, FALSE)` — défaut FALSE si NULL côté staging (cohérent avec V057 `NOT NULL DEFAULT FALSE`).
- UPDATE : sous la même garde temporelle.
- Règle : champs exclusifs à AC — aucune autre source ne les alimente.

**Stratégie temporelle (`updated_at_ac`, V058)**
- INSERT : `payload.updated_at` (timestamp API).
- UPDATE : `GREATEST(s.updated_at_ac, p.updated_at_ac)` — préserve la valeur la plus récente, jamais ne régresse.
- Règle métier : `updated_at_ac` est utilisé comme curseur d'incrémentalité (`MAX(updated_at_ac)` côté SQL pour calculer le `updated_at__gte` de la prochaine requête API). Ne doit jamais régresser, sinon on pourrait re-fetcher des aidants déjà à jour.

**Confidentialité, contact, soft delete personne, rôles, identifiants Coop/idposte**
- INSERT : ⚠️ ces champs **ne sont pas dans la col list de l'INSERT** (`etl/load/aidants_connect.py:135-148`). Si AC est la première source à connaître un aidant, ces champs restent NULL.
- UPDATE : non touchés.
- Règle : AC reste dans son scope. La désactivation d'un aidant **ne passe pas** par `deleted_at`/`deleted_by` côté personne, mais par `est_active = FALSE` côté affectations (post-V043).

**Métadata**
- `edited_by = 'aidants-connect'` : force sur INSERT et UPDATE.
- `created_at`, `updated_at`, `updated_at_coop`, `updated_at_idposte` : non touchés par AC.

### Stratégie de matching `main.personne` — comportement attendu

Pas de cascade. Match simple par `aidant_connect_id` UNIQUE. Détail : `etl/load/aidants_connect.py:23-153`.

| Cas réel | Étape | Action |
|---|---|---|
| Aidant déjà connu par `aidant_connect_id` | UPDATE (`:90-130`) sous garde `s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01')` | UPDATE des champs AC, marque `staging.matched=TRUE` |
| Pas encore connu | INSERT (`:135-148`) `WHERE s.matched=FALSE`, ON CONFLICT (aidant_connect_id) DO NOTHING | INSERT |

**Pourquoi pas de cascade ?** Contrairement à Coop qui peut connaître une personne via 3 identifiants (`coop_id`, `cn_pg_id`, `conseiller_numerique_id`), AC n'a que `aidant_connect_id`. La même personne peut exister par ailleurs avec un autre identifiant (ex : Coop), mais ce n'est pas AC qui fait la jointure — c'est `personne-similarities-merge` en aval.

### Désactivation d'un aidant (post-V043)

V043 a DROP `is_active_ac` de `main.personne` (la colonne n'existe plus). La désactivation passe désormais uniquement par `est_active = FALSE` côté `main.personne_affectations` ligne `source='aidants-connect'` (voir Section Affectations).

`ingest_utilisateurs` ne touche **pas** à `deleted_at`/`deleted_by` côté `main.personne`. La logique `is_active = u.get("is_active_ac", True)` (`etl/load/aidants_connect.py:628`) sert exclusivement à poser `est_active` côté affectations.

**Règle métier** : un aidant peut exercer simultanément côté AC et côté Coop. Si AC le désactive, on ne le rend pas globalement inactif — on désactive juste la ligne d'affectation `source='aidants-connect'`. Préserve les autres affiliations.

---

## Modèle de données — Affectations

### Où chercher

| Étape | Référence code |
|---|---|
| UPSERT principal | `etl/load/aidants_connect.py` `ingest_personne_affectations` (lookup + dédup + batch UPSERT) |
| Construction des rows | `etl/load/aidants_connect.py:617-629` |

### Schéma cible — `main.personne_affectations`

Schéma commun aux 3 sources. Description complète et migrations (V014, V019, V042, V043) : voir [`coop.md`](coop.md#schéma-cible--mainpersonne_affectations).

### Comportement par champ — AC sur `main.personne_affectations`

**Identifiants résolus par lookup**
- `structure_id` : lookup `main.structure` par `structure_ac_id`. Si pas trouvé → **skip toute la ligne** (compteur `skipped`).
- `personne_id` : lookup `main.personne` par `aidant_connect_id`. ⚠️ **Le code ne skip pas explicitement si NULL**. Mais `personne_id INTEGER NOT NULL` côté schéma (V014) → l'INSERT lèverait une violation. En pratique, `ingest_utilisateurs` insère toutes les personnes AC avant cet appel, donc le lookup ne doit jamais retourner NULL pour un aidant remonté. Robustesse à durcir (skip explicite + compteur) — voir notes amélioration dans `questions-metier-en-cours.md`.

**Type / source — constants**
- `type = 'structure_emploi'` (hardcodé)
- `source = 'aidants-connect'` (hardcodé)
- Règle : AC ne pose qu'un seul type d'affectation. Pas de `lieu_activite` (concept Coop uniquement).

**`est_active`**
- INSERT : `u.get("is_active_ac", True)` — TRUE par défaut si le payload ne fournit pas le champ.
- UPDATE : réécrit à chaque run (ON CONFLICT DO UPDATE SET est_active = EXCLUDED.est_active).
- Règle métier : reflète l'état courant côté AC. Quand un aidant est désactivé, la ligne reste en base mais `est_active = FALSE` — les vues aval (`api.aidants_connect`, `dataviz.structures_employeuses`) filtrent via `WHERE est_active = TRUE`.

**Déduplication intra-batch**
- Avant l'INSERT, dictionnaire Python clé `(structure_id, personne_id, type, source)`, dernière ligne gagne.

### Stratégie de matching

Match unique par `(structure_id, personne_id, type, source)` via `personne_affectations_unique_key`. Pas de cascade. ON CONFLICT DO UPDATE réécrit uniquement `est_active`.

### Règles cross-source

Voir tableau consolidé dans [`questions-metier-en-cours.md`](questions-metier-en-cours.md). AC pose toujours `(aidants-connect, structure_emploi)`. Cohabite avec `(coop, structure_emploi)` ou `(idposte, structure_emploi)` via la clé d'unicité — la même paire (personne, structure) peut donc avoir 2 ou 3 lignes selon les sources qui l'ont remontée.

### Garde-fous historiques (affectations)

Pas de fix isolé spécifique côté affectations AC. La règle "désactivation par `est_active`" (post-V043, février 2026) a centralisé le mécanisme : pas de soft-delete côté `main.personne` — la désactivation passe uniquement par `est_active = FALSE` côté affectations. Préserve la centralisation : chaque source désactive ses propres affectations sans toucher la personne globale.
