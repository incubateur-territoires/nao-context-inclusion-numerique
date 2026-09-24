# Conseillers Numériques (`schema-idPoste`)

> **Statut** : Sections 1 (vue d'ensemble + architecture), 2a (structures), 2b (personnes), 2c (affectations) et "Historique des fixes" couvertes. Sections **à compléter** : sous-systèmes postes, contrats, formations (logique d'agrégation/normalisation côté `postes_conum.py`). Subventions traitées dans [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md). Réconciliation aval pas encore documentée.
>
> **Doc complémentaire** : [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md) — système V1 (DGCL) / V2 (DITP+DGE) / bonifications QPV. Le présent doc couvre le DAG hors-subventions.
>
> **Questions métier ouvertes** : voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) (Q6).

## Vue d'ensemble

Le DAG `schema-idPoste` ingère les données de pilotage du dispositif **Conseillers Numériques France Services (CoNum)** depuis un fichier CSV de gestion centralisée (PMU/PNM) maintenu côté ANCT/État. Il transforme ces données brutes en postes, personnes, structures, contrats, formations et subventions, puis les charge dans `main.*` et déclenche les DAGs de réconciliation aval.

Source amont : CSV CoNum (un row par conseiller numérique affecté), récupéré via S3 (`IDPOSTE_S3_BUCKET`), avec fallback local `/opt/airflow/data/conum.csv` (convention dev).

## Architecture du pipeline

```
[CSV CoNum (S3 ou local)]
        │
init_working_dir → download_file
        │
process_data_conum
   (etl/transform/ingest/postes_conum.py:main())
        │
        ├─► structure.csv
        ├─► poste.csv
        ├─► personne.csv
        ├─► formation.csv
        └─► subvention.csv (déjà agrégée par poste_id, V1+V2 avec bonifs QPV)
        │
get_structure_file_and_process (enrichissement SIRENE + BAN via API_SIRENE_TOKEN)
        │
process_enriched_structure
   (batch upsert : main.adresse → main.structure → main.contact, main.contact_structure)
        │
process_personne_upsert_file (main.personne, is_mediateur=TRUE, edited_by='id-poste')
        │
        ├─► truncate_contrat_table → process_contrat_file (main.contrat)
        │     │
        │     └─► process_personne_affectations_file
        │         (main.personne_affectations type='structure_emploi' source='idposte',
        │          est_active calculé via LEFT JOIN main.contrat actif)
        │
        ├─► truncate_poste_table → process_poste_file (main.poste)
        │
        ├─► truncate_formation_table → process_formation_file (main.formation)
        │
        └─► truncate_subvention_table → process_subvention_file (main.subvention)
                │
                └─► trigger structures-similarities-merge (reset_dag_run=True — voir Q6)
                └─► trigger personne-similarities-merge (reset_dag_run=True)
```

## Schedule et déclenchement

- **Schedule** : `None` — déclenché manuellement ou via `ci-cd-schema-idPoste` (cron `timedelta(weeks=2)`).
- **Start date** : 2024-09-04 02:00 Europe/Paris.
- **Timeout** : 25 heures (`dagrun_timeout=1500 min`).
- **Retries** : 0. **Catchup** : False.
- **Tags** : `["inclusion-numerique", "id-poste"]`.

## Auth et configuration

| Élément | Valeur / Variable |
|---|---|
| `db_conn_id` | param enum (défaut `sonum-prod-db`) |
| Working dir | param `/tmp/tmp.8EE4C22C` (statique — note "à améliorer") |
| `IDPOSTE_S3_BUCKET` | Variable — bucket source CSV (fallback local pour dev) |
| `s3_idposte` | Connection — S3 |
| `API_SIRENE_TOKEN` | Variable — enrichissement structures |
| `MATTERMOST_*` | Variables — notifs |

CSV separator : `;`. Marqueur source à chaque INSERT/UPDATE : `edited_by='id-poste'`.

## Param `freeze` ou équivalent

**Non applicable.** Pas de param `freeze`. Stratégie de remplacement complet par `TRUNCATE` sur `main.poste`, `main.contrat`, `main.formation`, `main.subvention` à chaque run. `main.personne` et `main.structure` sont en upsert.

## Règles métier explicites importantes

1. **`is_mediateur=TRUE` systématique** — toutes les personnes insérées sont marquées médiateur (`schema-idPoste.py:212`). Pas de notion de coordinateur côté CoNum (un seul rôle = conseiller numérique = médiateur).

2. **`edited_by='id-poste'`** sur tout INSERT/UPDATE — marqueur source pour les autres DAGs.

3. **`personne_affectations type='structure_emploi' source='idposte'`** — ce DAG pose les emplois "officiels" CoNum. Coop pose **aussi** des `structure_emploi` mais uniquement pour les utilisateurs **sans `cn_pg_id`**. Pas de doublon cross-source.

4. **`est_active` calculé en LEFT JOIN sur `main.contrat`** — affectation active ssi au moins un contrat sans `date_rupture` pour la paire (personne, structure) (`schema-idPoste.py:308-317`).

5. **Subventions agrégées par poste** — le CSV source a une ligne par conseiller, agrégé en une ligne par `poste_id` : `SUM` montants, `MAX` bonifications, `FIRST` dates. Voir [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md) pour détails QPV.

6. **Normalisations explicites** dans `postes_conum.py` :
   - États instructions : `'convention "refusée"'` → `'refusée'`, lowercased.
   - Typologies postes : seuls `"conum"`, `"coordo"`, `"dns"` ; autres → NULL.
   - Lieux formation : title-case + corrections manuelles (ex: `"Clermont Ferrand"` → `"Clermont-Ferrand"`).
   - Types contrat : `CDP`, `CDD`, `CDI`, `PEC` (variantes mappées).

## Réconciliation aval

Trois tâches finales (`process_formation_file_task`, `process_subvention_file_task`, `process_contrat_file_task`) déclenchent chacune les deux DAGs de réconciliation :
- `structures-similarities-merge`
- `personne-similarities-merge`

Avec `reset_dag_run=True` (voir Q6).

---

## Modèle de données — Structures

### Où chercher

| Étape | Référence code |
|---|---|
| Extract + transform | `etl/transform/ingest/postes_conum.py::main()` (CSV CoNum → `structure.csv`, `poste.csv`, `personne.csv`, `formation.csv`, `subvention.csv`) |
| Enrichissement SIRENE+BAN | `schema-idPoste.py` `get_structure_file_and_process` (pas de cutoff — enrichit systématiquement) |
| INSERT/UPDATE batch | `schema-idPoste.py` `process_enriched_structure` (UPDATE fallback `:921-945` + INSERT batch `:949-980`) |
| Tables associées (contact / contact_structure) | `schema-idPoste.py` étapes 4-5 de `process_enriched_structure` |

### Schéma cible — `main.structure`

Schéma commun aux 4 sources. Description complète et migrations : voir [`coop.md`](coop.md#schéma-cible--mainstructure).

### Comportement par champ — schema-idPoste sur `main.structure`

**Identité (`structure_tp_id`, `nom`, `siret`, `publique`)**
- INSERT : `structure_tp_id` ← `id_structure` du CSV (entier, NULL si NA), `nom` ← `nom_structure.title()` (capitalisation propre), `siret` ← `zfill(14)` validé, `publique` ← `True si "Publique" sinon False`.
- UPDATE (UPDATE fallback) : `structure_tp_id` adopté via assignment direct, protégé par `WHERE s.structure_tp_id IS NULL` (n'écrase jamais une valeur AC/Coop). Les autres champs identité non touchés (clés de matching).
- Règle métier : on adopte le `structure_tp_id` sur une ligne créée par une autre source pour unifier.

**Adresse (`adresse_id`)**
- INSERT : résolution en cascade — UPSERT `main.adresse` par batch sur clé composite `(code_postal, nom_commune, nom_voie, numero_voie, repetition)` ; lookup `adresse_id` priorité 1 = `code_ban`, priorité 2 = `clef_interop` ; fallback NULL → ligne ignorée pour la suite (warning log).
- UPDATE (UPDATE fallback) : `adresse_id` réécrit (sans COALESCE).
- Règle : pas d'orphelinage — pas d'INSERT sans adresse résolue.

**SIRENE (`etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene`)**
- INSERT : depuis SireneBatch (lookup par siret).
- UPDATE (UPDATE fallback) : `COALESCE(s.x, v.x)` — préserve l'existant si la valeur incoming est NULL ou si l'existant est déjà rempli (par AC/Coop).
- Règle métier : asymétrique vis-à-vis d'AC. AC écrase l'existant sous garde temporelle ; idposte préserve l'existant via COALESCE. Pas de cutoff — enrichit systématiquement à chaque run (lot CoNum modeste). Q19 : faut-il harmoniser ?

**`rna`, `source`, `last_sirene_enrich_at`**
- INSERT : non inclus dans `structure_columns` (`schema-idPoste.py:805-809`). Si Coop ou AC les a posés, valeurs préservées.
- UPDATE : non touchés.
- Règle : `source` est typiquement Carto (origine du lieu) ; idposte ne se prononce pas. `last_sirene_enrich_at` non posé car pas de cutoff — Q19.

**Tables associées — `main.contact` + `main.contact_structure` (V047)**
- INSERT : registre dédupliqué via `main.contact` (clé `(email, nom, prenom, fonction)`, fonction fixe `'Référent tableau de pilotage'`). Source : JSON `contact` généré par `create_contact_column()` dans `postes_conum.py` à partir de `nom_referent_tp`, `prenom_referent_tp`, `telephone`, `mail_gestionnaire`, `mail_2`, `referent_hierarchique`. Lien N:N via `main.contact_structure` (ON CONFLICT DO NOTHING).
- Règle : idposte est la **seule source** qui alimente correctement les nouvelles tables contact post-V047. Coop, AC continuent d'écrire dans `main.structure.contact` JSONB déprécié — **Q14 ouverte** sur la cohabitation.

**Catégories `TEXT[]`, présentation, contact JSONB structure**
- INSERT : non inclus dans `structure_columns`.
- UPDATE : non touchés.
- Règle : idposte se concentre sur l'identité légale + référent. Les valeurs métier viennent de Coop ou Carto.

**Métadata**
- `edited_by = 'id-poste'` : constante (`EDITED_BY` au top du DAG), force sur INSERT et UPDATE.

**Champs cibles non touchés par schema-idPoste**
- Identifiants externes : `structure_coop_id`, `structure_ac_id`, `structure_cartographie_nationale_id`.
- Champs propres à d'autres sources : `nb_mandats_ac` (AC), `visible_pour_cartographie_nationale`, `fiche_acces_libre` (Carto), `mediateurs_en_activite`, `emplois` (Coop), `deleted_at`/`deleted_by` côté structure (AC).
- ⚠️ Pas de timestamp `updated_at_idposte` côté `main.structure` (V064 a ajouté ces colonnes par source uniquement sur `main.personne`). Conséquence : pas de comparator temporel sur structure côté idposte — le `COALESCE` préserve l'existant, pas une comparaison de fraîcheur.

### Stratégie de matching `main.structure` — comportement attendu

Pas de CTE multi-branche. 2 étapes séquentielles dans `process_enriched_structure`. Pour la mécanique exacte, lire `schema-idPoste.py:921-980`.

| Cas réel | Étape | Action |
|---|---|---|
| Structure déjà créée par une autre source (Coop, AC) avec mêmes `(siret, LOWER(nom), adresse_id)` mais sans `structure_tp_id` | UPDATE fallback (`:921-945`) | UPDATE des champs SIRENE (avec COALESCE) + adoption du `structure_tp_id` (guard `s.structure_tp_id IS NULL`) |
| Pas de match → INSERT batch (`:949-980`) ON CONFLICT DO NOTHING | INSERT |
| Doublon intra-batch sur `structure_tp_id` | dédup Python avant l'INSERT | Une seule ligne envoyée |

**Pourquoi l'UPDATE fallback ?** Cas cross-source symétrique à Coop / AC : une structure créée par Coop puis remontée par schema-idPoste via le CSV CoNum. Sans cette étape, on créerait un doublon. Adoption du `structure_tp_id` sur la ligne Coop existante via assignment direct protégé par la garde `IS NULL` (ne casse pas un `structure_tp_id` déjà posé).

### Garde-fous historiques (structures)

Pas de fix isolé spécifique à schema-idPoste en avril 2026. Évolutions du sous-système subventions : voir [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md).

---

## Modèle de données — Personnes

### Où chercher

| Étape | Référence code |
|---|---|
| Extract + transform | `etl/transform/ingest/postes_conum.py::main()` produit `personne.csv` |
| UPSERT principal | `schema-idPoste.py` `process_personne_upsert_file` (batch 500, INSERT ON CONFLICT) |

### Schéma cible — `main.personne`

Schéma commun aux 3 sources qui écrivent. Description complète et migrations : voir [`coop.md`](coop.md#schéma-cible--mainpersonne).

### Comportement par champ — schema-idPoste sur `main.personne`

**Identifiant externe (`cn_pg_id`, INTEGER UNIQUE)**
- INSERT : `cn_pg_id` ← `personne.csv "cn_pg_id"` (entier validé `.notna()`). Lignes sans `cn_pg_id` filtrées avant l'INSERT. Dédup intra-batch : `drop_duplicates(subset=["cn_pg_id"], keep="first")`.
- UPDATE : jamais — clé du `ON CONFLICT`.
- Règle : `cn_pg_id` est l'identifiant officiel CoNum, stable et unique côté ANCT/État. Source d'autorité.

**Identité (`nom`, `prenom`)**
- INSERT : depuis `personne.csv` (NULL si NaN).
- UPDATE : `COALESCE(main.personne.x, EXCLUDED.x)` — **préserve l'existant si déjà rempli**.
- Règle métier : asymétrique vis-à-vis de Coop (qui force) et AC (qui écrase sous garde temporelle). idposte est conservateur sur l'identité — n'écrase pas une valeur posée par une autre source. Logique : une fois la personne nommée correctement par sa source d'origine (Coop/AC), idposte ne réécrit pas avec une éventuelle variante du CSV CoNum.

**Contact JSONB (déprécié V047)**
- INSERT : depuis `personne.csv "contact"` (JSON-string déjà construit par `postes_conum.py::create_emails_column_personne`, format `{"idposte": {mail_pro?, mail_perso?}}`, NULL si vide).
- UPDATE : merge JSONB via `||` — préserve les clés posées par d'autres sources, ajoute / écrase la clé `"idposte"`.
- Règle : colonne dépréciée par V047. idposte continue d'écrire — **Q14 ouverte**.

**Rôle (`is_mediateur`)**
- INSERT : `TRUE` (constante hardcodée `schema-idPoste.py:212`).
- UPDATE : `TRUE` (force).
- Règle métier explicite : tous les CN sont médiateurs (par définition du dispositif). Pas de notion de coordinateur côté CoNum (un seul rôle = conseiller numérique = médiateur). Évite les ambiguïtés cross-source au merge.

**Stratégie temporelle (`updated_at_idposte`, V064)**
- INSERT : `now()` (côté SQL, dans la clause VALUES).
- UPDATE : `EXCLUDED.updated_at_idposte` = `now()` de l'incoming. Toujours réécrit.
- Règle : pas de comparator temporel pour décider l'UPDATE — l'UPDATE est inconditionnel sur `ON CONFLICT (cn_pg_id)`. Le timestamp sert uniquement aux autres sources (Coop) pour leur propre garde temporelle.

**Métadata**
- `edited_by = 'id-poste'` : force sur INSERT et UPDATE.

**Champs cibles non touchés par schema-idPoste**
- Identifiants externes : `coop_id`, `conseiller_numerique_id`, `aidant_connect_id`.
- Champs propres à d'autres sources : `is_coordinateur`, `is_visible` (Coop), `is_referent_ac`, `formation_fne_ac`, `profession_ac`, `nb_accompagnements_ac`, `updated_at_ac` (AC), `updated_at_coop` (Coop), `deleted_at`, `deleted_by` (Coop seulement côté personne).

### Stratégie de matching `main.personne` — comportement attendu

Pas de cascade. Match simple par `cn_pg_id` UNIQUE.

| Cas réel | Action |
|---|---|
| Personne déjà connue par `cn_pg_id` | ON CONFLICT DO UPDATE — réécrit sous COALESCE/merge |
| Personne pas encore connue | INSERT direct |

**Pourquoi pas de cascade ?** `cn_pg_id` est l'identifiant stable et unique côté CoNum officiel. Pas besoin de matcher sur autre chose côté idposte — la jointure cross-source (avec `coop_id` / `aidant_connect_id`) est faite par les DAGs `*-similarities-merge` en aval.

### Garde-fous historiques (personnes)

- **`is_mediateur = TRUE` systématique** (`schema-idPoste.py:212`) — règle métier explicite : tous les CN sont médiateurs par définition. Garde-fou cross-source : chaque source applique son axiome de rôle, évite les ambiguïtés au merge.

---

## Modèle de données — Affectations

### Où chercher

| Étape | Référence code |
|---|---|
| UPSERT principal | `schema-idPoste.py:224-327` `process_personne_affectations_file` |
| Calcul `est_active` (LEFT JOIN contrat) | `schema-idPoste.py:308-317` |

### Schéma cible — `main.personne_affectations`

Schéma commun aux 3 sources. Description complète et migrations (V014, V019, V042, V043) : voir [`coop.md`](coop.md#schéma-cible--mainpersonne_affectations).

### Comportement par champ — schema-idPoste sur `main.personne_affectations`

**Identifiants résolus par lookup**
- `personne_id` : lookup `main.personne` par `cn_pg_id`. Skip si pas trouvé.
- `structure_id` : lookup `main.structure` par `structure_tp_id`. Skip si pas trouvé.
- Filtrage incoming : seules les lignes avec `cn_pg_id.notna() AND structure_tp_id.notna()` ; dédup Python par `(cn_pg_id, structure_tp_id)`.

**Type / source — constants**
- `type = 'structure_emploi'` (hardcodé)
- `source = 'idposte'` (hardcodé)
- Règle : idposte ne pose qu'un seul type (l'emploi déclaré dans le CSV CoNum). Pas de `lieu_activite`.

**`est_active` — calculé en SQL**
- INSERT : calculé via LEFT JOIN sur `main.contrat` au moment de l'INSERT — `est_active = TRUE` ssi il existe au moins un contrat actif (sans `date_rupture`) pour la paire `(personne, structure)`.
- UPDATE : recalculé à chaque run (ON CONFLICT DO UPDATE SET est_active = EXCLUDED.est_active).
- Règle métier : affectation active ⇔ contrat en cours. Quand un conseiller quitte (contrat rompu), l'affectation ne reste pas "active" zombie. La source de vérité est `main.contrat`, pas un état dupliqué.
- ⚠️ **Timing** : `est_active` est calculé au run du DAG, pas live. Une rupture enregistrée en base après le dernier run ne se reflète qu'au run suivant.

### Stratégie de matching

Match unique par `(structure_id, personne_id, type, source)` via `personne_affectations_unique_key`. Pas de cascade. ON CONFLICT DO UPDATE réécrit uniquement `est_active`. Dédup Python (`seen` set) avant batch SQL pour éviter les doublons côté DB.

### Règles cross-source

Pose `(structure_emploi, idposte)` pour tous les CoNum officiels. La clé d'unicité `(structure_id, personne_id, type, source)` permet à idposte et Coop de coexister sur la même paire en pratique. Mais Coop n'écrit `structure_emploi` que si `cn_pg_id IS NULL OR conseiller_numerique_id IS NULL` (= utilisateur Coop pas pleinement identifié comme CoNum, `http_airflow.py:702`). Donc dans le cas standard CoNum (les **deux** identifiants présents), seule la ligne `(structure_emploi, idposte)` est posée — pas de doublon sémantique. Voir tableau dans [`questions-metier-en-cours.md`](questions-metier-en-cours.md).

### Garde-fous historiques (affectations)

- **`est_active` calculé via LEFT JOIN `main.contrat`** (`schema-idPoste.py:308-317`) — garde contre les affectations zombies. Le LEFT JOIN garantit dépendance sur la source de vérité (`main.contrat`), pas d'état dupliqué qui pourrait diverger.
