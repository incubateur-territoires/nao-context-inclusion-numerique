# Plan de refonte `main.structure` — phases et invariants

> **Statut** : plan d'exécution du projet de refonte (cf
> [`refonte-structure-modelisation.md`](refonte-structure-modelisation.md)
> pour le cadrage et les décisions de modélisation,
> [`refonte-structure-metriques.md`](refonte-structure-metriques.md) pour
> les compteurs de non-régression utilisés à chaque jalon).
>
> Chaque phase liste : **ce qu'on fait**, **le diff attendu** (invariant
> validable via `scripts/rapport_all.sh diff`), **durée estimée**,
> **risque**, et **conditions de rollback**.

## Décisions modélisation actées (rappel)

- **Q2** Clé naturelle de `lieu_inclusion` : `structure_cartographie_nationale_id` UNIQUE (seul, pas `(nom, adresse_id)`)
- **Q8** Affectations : 2 tables séparées (`personne_affectations_emploi` + `personne_affectations_lieu`)
- **Q5** Orphelines : à supprimer avant migration (phase 0.5)
- **Q7** Vue de compat `main.structure_v_compat` pendant la transition
- Q3 (type asso) / Q4 (lieu sans employeuse) / Q6 (source côté employeuse) : reportés / par défaut

## Stratégie de déploiement : big bang strict

Tout le code (5 migrations Flyway + 4 DAGs modifiés + 5 vues api.* + MIN)
est développé et validé en local sur `basederef.custom`, puis sur
`dataspace_test` via le pipeline CI/CD. Une fois le verdict OK, déploiement
des phases 1 à 6 **en une seule fenêtre** sur la prod (jour J coordonné
avec MIN).

**Conséquence** : **pas de double écriture** dans les DAGs. Code simple
mais une seule fenêtre de validation et un rollback "coûteux" (`pg_restore`
du dump pré-déploiement) en cas de problème post-bascule.

**Conditions de réussite** :
- Pré-prod fidèle à la prod (`basederef.custom` régulièrement refresh)
- CI/CD verdict intégrant `rapport_all.sh diff` (à automatiser)
- Coordination jour J avec l'équipe MIN
- Dump prod fraîchement pris juste avant la fenêtre de déploiement

**Plan de rollback** :
- Avant phase 6 (DROP) : revert des MRs DAG + script de resync ancien
  modèle ← nouveau (à scripter en amont)
- Après phase 6 : `pg_restore` du dump pré-déploiement (downtime
  inévitable)

## Phase 0 — Baseline ✅ FAIT

Métriques en place :
- `scripts/rapport_structures.py` + `rapport_all.sh` (orchestrateur des 5 rapports)
- Snapshot `snapshots/phase0_baseline_2026-05-21/` commité

Point zéro de référence pour tous les diffs des phases suivantes.

## Phase 0.5 — Nettoyage des données (préalable)

**Objectif** : assainir les ~16 000 lignes pathologiques qui ne tiendront
pas dans le nouveau modèle, **avant** de toucher au schéma. Le modèle
cible `structure_administrative` exige `siret UNIQUE NOT NULL` ; or 19 utilisateurs
MIN + 27 membres MIN sont rattachés à des structures **sans SIRET** en base
(25 structures distinctes, cf 0.5.b), et **16 023 lignes sont orphelines**
au sens strict (aucune FK ne pointe vers elles → suppression sûre).

### 0.5.a — Audit des orphelines (✅ outil prêt)

**Définition stricte adoptée** : une structure est orpheline si **aucune
FK** ne pointe vers elle parmi ces 8 tables :
- `main.personne_affectations.structure_id` (active **ou** inactive)
- `main.contrat.structure_id`
- `main.poste.structure_id`
- `main.contact_structure.structure_id`
- `main.activites_coop.structure_id`
- `min.membre.structure_id`
- `min.utilisateur.structure_id`
- `import.carto.structure_id`

C'est une condition **plus stricte** que "sans affectation active ni
carto_id" : on garde notamment les ~3 769 structures qui ont des
affectations inactives, des contrats historiques, des références MIN
résiduelles, etc. Ces structures portent une trace historique utile et
ne sont **pas** des candidates à suppression naturelle.

Script : `scripts/audit_orphelines_fk.py`
- Lance la requête sur la définition stricte
- Output : compteur en stdout + CSV optionnel (`-o orphelines.csv`)
- Breakdown par `edited_by` pour identifier d'où viennent ces résidus

Mesure phase 0 (2026-05-21) :
- **16 023 vraies orphelines** au total
- Par source : carto 11 665, coop 2 294, aidants-connect 1 314,
  migrate_ac_addresses.py 744, app_python (MIN) 6

**Vérification sûreté** : 0 des 16 023 n'apparaît dans `api.carto`
(ni dans les autres `api.*`) — pour apparaître il faut au moins une
affectation active, ce qui est exclu par la définition d'orpheline.

**Diff attendu (audit seul)** : 0 (lecture seule).

### 0.5.b — Résolution SIRENE *best effort* des structures sans SIRET (~1-2 jours)

**Non bloquante** depuis l'adoption du schéma permissif (cf décision
tranchée "SIRET NULL accepté"). On résout ce qu'on peut auto, on laisse
le reste tel quel.

Cas mesurés en phase 0 :
- 19 utilisateurs MIN + 27 membres MIN rattachés à des structures sans SIRET
- **25 structures distinctes** (overlap : 17 portent à la fois 1 membre +
  1 user, 7 ont juste un membre, 1 a juste un utilisateur)
- Par catégorie : 11 **communes** + 13 **structures diverses** + 1 sans membre
- Parmi les 25 : **12 ont au moins un identifiant externe** (coop_id, carto_id…)
  qui sécurise l'unicité ; **13 (toutes `edited_by=min_scalingo`) n'ont rien
  du tout** (créées via UI MIN sans ancrage SIRENE — APF France handicap,
  Conseil national du numérique, La Coop Num…).

**Étapes** :
- Pour les **11 communes** : recherche SIRENE par `nom + code_insee` →
  match unique attendu (toutes les communes françaises ont un SIRET de
  mairie au format `2<code_insee>00<NIC>`). UPDATE direct.
- Pour les **13 structures diverses** : recherche SIRENE par
  `nom + code_postal + nom_commune` quand on a une adresse.
  Match unique fiable → UPDATE ; ambigu / pas de match → on laisse en l'état.
- Les **13 cas min_scalingo sans aucune adresse** (tous pointent sur
  `adresse_id = 109396` vide) : non résolvables sans intervention manuelle.
  **On les garde tels quels** en `structure_administrative` sans SIRET.
- **Cas RIDET (Nouvelle-Calédonie / Polynésie)** : le schéma cible
  (phase 1) prévoit une colonne `ridet` séparée. Aucune occurrence
  actuelle, support prévu pour le futur.

**Diff attendu** :
- Cas résolus (≈ 11 communes + quelques structures diverses) :
  `rapport_structures` "Avec structure (siret manquant)" baisse de N,
  "Avec structure (siret renseigné)" monte de N.
- Cas non résolus restent avec `siret IS NULL` — acceptable, le schéma
  l'autorise.

**Plus de décision ouverte sur "que faire des cas non résolus"** :
le schéma permissif gère naturellement ces cas.

### 0.5.c — Suppression des orphelines (~1 jour)

Une fois l'audit 0.5.a validé et les cas 0.5.b résolus :

- Migration Flyway `V0NN__cleanup_main_structure_orphelines.sql` :
  - `DELETE FROM main.structure WHERE id IN (<liste 16 023 ids depuis audit_orphelines_fk.py -o>)`
  - Le DELETE est trivialement sûr puisque par construction aucune FK
    ne pointe vers ces structures (cf 0.5.a)
- Migration `V0NN+1__cleanup_main_adresse_orphelines.sql` (optionnel) : si
  des adresses ne sont plus référencées après le DELETE des structures, les
  supprimer aussi.

**Diff attendu post-0.5** :

| Métrique | Avant | Après | Écart attendu |
|---|---|---|---|
| `main.structure` total | 44 728 | ~28 705 | **−16 023** |
| `main.structure` vraies orphelines (aucune FK) | 16 023 | 0 | −16 023 |
| `main.structure` sans aff active ni carto_id (large) | 19 792 | 3 769 | −16 023 |
| `main.structure` pures employeuses | 5 432 | 5 432 | 0 |
| `main.structure` pures lieux | 17 522 | 17 522 | 0 |
| `main.structure` mixtes | 1 982 | 1 982 | 0 |
| `api.carto` lignes exposées | 15 168 | 15 168 | 0 |
| Utilisateurs MIN avec structure | 1 513 | 1 513 | 0 |
| Utilisateurs MIN sans SIRET | 19 | 0 (idéal) | −19 |
| Membres MIN sans SIRET | 27 | 0 (idéal) | −27 |

→ Toute déviation hors de ces bornes = à investiguer avant de passer en
phase 1.

**Durée totale phase 0.5** : 1-2 semaines selon volume escalades métier.
**Risque** : faible-moyen. Risque principal = escalade non-résolue (cas
sans SIRET résolu). Conservation possible : laisser ces structures et
les traiter en phase 0.5 bis post-MVP.
**Rollback** : restoration via `pg_restore basederef.custom`. Aucune
modification consommateur, rollback trivial.

## Phase 1 — Schéma cible vide

**Objectif** : créer les 5 nouvelles tables avec leurs contraintes. Aucune
donnée déplacée.

**Migrations Flyway** :
- `V0NN__schema_structure_administrative.sql` :
  - PK auto
  - **`siret` UNIQUE NULL** `VARCHAR(14)` CHECK `~ '^\d{14}$'` — identifiant métropole, nullable (cf décision tranchée "SIRET NULL accepté")
  - **`ridet` UNIQUE NULL** `VARCHAR(10)` CHECK `~ '^\d{7,10}$'` — identifiant Nouvelle-Calédonie / Polynésie, nullable
  - **Pas de CHECK obligatoire** `siret IS NOT NULL OR ridet IS NOT NULL` — on accepte les structures sans identifiant SIRENE (cas MIN historique : assos, organismes nationaux sans SIRET établi). L'unicité reste garantie dès qu'un identifiant externe est posé (siret, ridet, structure_coop_id, _tp_id, _ac_id, _cartographie_nationale_id — tous UNIQUE)
  - `denomination_sirene`, `adresse_id` FK
  - Identifiants cross-source : `structure_coop_id`, `structure_tp_id`, `structure_ac_id`
  - SIRENE : `etat_administratif`, `code_activite_principale`, `categorie_juridique`, `rna`
  - AC : `nb_mandats_ac`
  - Soft-delete : `deleted_at`, `deleted_by[]`
  - Audit : `edited_by`, `created_at`, `updated_at`, `updated_at_coop`, `updated_at_idposte`, `updated_at_ac`, `last_sirene_enrich_at`
  - `contact` JSONB **conservé en héritage de `main.structure`** (dépréciation V047 non close par cette refonte — voir Décisions tranchées)
  - Migration associée : `main.contact_structure` → renommé `main.contact_structure_administrative`, FK changée vers `structure_administrative(id)`
- `V0NN+1__schema_lieu_inclusion.sql` :
  - PK auto, `nom` NOT NULL, `adresse_id` FK NOT NULL
  - **`structure_cartographie_nationale_id` UNIQUE** (nullable, identifiant mednum-cli)
  - `visible_pour_cartographie_nationale`, `fiche_acces_libre`
  - `horaires`, `prise_rdv`, `itinerance` TEXT[]
  - `services`, `modalites_acces`, `modalites_accompagnement` TEXT[]
  - `publics_specifiquement_adresses`, `prise_en_charge_specifique`, `frais_a_charge` TEXT[]
  - `formations_labels`, `autres_formations_labels`, `dispositif_programmes_nationaux` TEXT[]
  - `presentation_resume`, `presentation_detail`
  - **`contact` JSONB** (coordonnées publiques anonymes : `telephone`, `courriels`, `site_web`). Sémantiquement distinct du JSONB côté employeuse (qui contient des référents nommés), pas une dette V047.
  - `source` (origine mednum), `edited_by`, timestamps
- `V0NN+2__schema_lieu_inclusion_structure_administrative.sql` :
  - `lieu_id` FK + `structure_administrative_id` FK, UNIQUE composé, `created_at`, `edited_by`
- `V0NN+3__schema_personne_affectations_emploi.sql` :
  - `personne_id` FK + `structure_administrative_id` FK + `source` (CHECK in coop/idposte/aidants-connect) + `est_active` + timestamps
- `V0NN+4__schema_personne_affectations_lieu.sql` :
  - `personne_id` FK + `lieu_id` FK + `source` + `est_active` + timestamps

**Diff attendu** : **strictement 0** sur tous les compteurs existants. Si
un diff sort, on a cassé quelque chose involontairement (cascade FK ?
trigger ? hook ?).

**Durée** : 2-3 jours
**Risque** : faible
**Rollback** : `DROP TABLE ... CASCADE` sur les 5 nouvelles tables, ou
restore `basederef.custom`.

## Phase 2 — Peuplement initial (sans bascule)

**Objectif** : matérialiser les nouvelles tables depuis `main.structure`,
sans toucher aux DAGs ni aux consommateurs. La donnée est dupliquée pendant
la transition.

**Migrations** :
- `V0NN+5__populate_structure_administrative.sql` :
  - INSERT depuis `main.structure` pures employeuses + mixtes
  - **7 414 lignes attendues** (5 432 + 1 982)
  - **Règle JSONB contact** :
    - Pures employeuses avec nom/prenom (903) → copier le JSONB intégralement
    - Pures employeuses avec coords génériques uniquement (129) → `contact = NULL` (décision : pas de valeur métier pour ces coordonnées de siège isolées)
    - Mixtes → ne garder que les clés `nom`/`prenom` du JSONB (les coords vont côté lieu)
- `V0NN+6__populate_lieu_inclusion.sql` :
  - INSERT depuis `main.structure` pures lieux + mixtes
  - **19 504 lignes attendues** (17 522 + 1 982)
  - **Règle JSONB contact** :
    - Pures lieux → copier `telephone`, `courriels`, `site_web` du JSONB (les ~7 anomalies nom/prenom sur lieux sont jetées)
    - Mixtes → copier `telephone`, `courriels`, `site_web` du JSONB (les nom/prenom restent côté employeuse)
- `V0NN+7__populate_asso.sql` :
  - INSERT couples lieu ⋈ employeuse pour les 1 982 mixtes
  - **1 982 lignes attendues**
- `V0NN+8__populate_affectations_emploi.sql` :
  - INSERT depuis `main.personne_affectations WHERE type = 'structure_emploi'`
  - **18 880 affectations actives + 12 374 inactives = 31 254 attendues** (selon phase 0)
- `V0NN+9__populate_affectations_lieu.sql` :
  - INSERT depuis `main.personne_affectations WHERE type = 'lieu_activite'`
  - **14 384 attendues**
- `V0NN+10__rename_contact_structure.sql` :
  - `ALTER TABLE main.contact_structure RENAME TO contact_structure_administrative`
  - Refonte de la FK pour pointer sur `structure_administrative(id)` au lieu de `main.structure(id)` — peuplée via le mapping main.structure.id → structure_administrative.id établi en V0NN+5
  - **4 313 lignes préservées** (toutes les entrées V047 actuelles, qui pointent toutes sur des employeuses ou mixtes)

**Vue de compat** :
- `V0NN+10__view_main_structure_compat.sql` : crée `main.structure_v_compat`
  qui projette `structure_administrative LEFT JOIN asso LEFT JOIN lieu_inclusion`
  pour reproduire l'ancienne sémantique. Pas activée en remplacement de
  `main.structure` à ce stade — juste prête à servir.

**Diff attendu post-phase 2** :

| Métrique | Avant | Après | Attendu |
|---|---|---|---|
| `main.structure` total | ~25 000 (post-0.5) | ~25 000 | 0 (inchangé) |
| `main.personne_affectations` | 45 638 | 45 638 | 0 |
| `api.carto` | 15 168 | 15 168 | 0 (pas encore basculé) |
| Rattachement MIN | inchangé | inchangé | 0 |
| Nouvelles tables : `structure_administrative` | 0 | 7 414 | +7 414 |
| Nouvelles tables : `lieu_inclusion` | 0 | 19 504 | +19 504 |
| Nouvelles tables : `lieu_inclusion_structure_administrative` | 0 | 1 982 | +1 982 |
| Nouvelles tables : `personne_affectations_*` | 0 | 31 254 + 14 384 | total = 45 638 |

→ La somme des nouvelles affectations doit **égaler exactement** l'ancien total.
Si écart, données perdues lors du split.

**Durée** : 1 semaine
**Risque** : faible-moyen (cas mixtes à bien gérer, asso correcte)
**Rollback** : `DELETE FROM` les nouvelles tables (laisser le schéma).

## Phase 3 — Bascule du premier DAG : `schema-idPoste`

**Objectif** : valider l'approche sur le DAG le plus simple. idposte
écrit uniquement des employeuses + leurs affectations `structure_emploi`.

**Étapes** :
- Modifier `schema-idPoste.py` pour écrire dans `structure_administrative`
  + `personne_affectations_emploi` au lieu de `main.structure` +
  `main.personne_affectations`. **Bascule franche** (pas de double écriture
  — cf stratégie de déploiement).
- Refondre `structures-similarities-merge` côté employeuses : devient
  `structure_administrative-similarities-merge`, fusionne par SIRET.
- Validation en local : `pg_restore basederef.custom` →
  `rapport_all.sh snapshot avant` → run DAG idposte sur le nouveau code →
  `rapport_all.sh diff avant` → vérifier que les invariants tiennent.
- Validation CI/CD sur `dataspace_test` (restore backup prod, run, snapshot,
  verdict).

**Diff attendu après un run du DAG (en pré-prod)** :
- `structure_administrative` : variation cohérente avec les imports du jour
  (delta typique pour un CSV CoNum d'un run)
- `main.structure` (legacy) : 0 (n'est plus alimentée par idposte)
- `rapport_validation` : valeurs idposte (postes, contrats, subventions)
  **strictement identiques** au snapshot avant — c'est l'invariant clé.

**Durée** : 1 semaine (codage + validation locale + validation CI/CD)
**Risque** : moyen (premier DAG = on construit la convention pour les suivants)
**Rollback (intermédiaire, avant phase 6)** : revert du commit DAG +
script `resync_legacy.py` qui copie `structure_administrative → main.structure`
depuis le delta du jour. À avoir prêt avant la fenêtre de bascule.

## Phase 4 — Bascule des autres DAGs

Même approche, par ordre de complexité croissante :

| DAG | Cible | Particularité |
|---|---|---|
| 4a. `aidants-connect-import` | `structure_administrative` + `personne_affectations_emploi` | Simple (employeuse seule), soft-delete via `deleted_at`/`deleted_by` à transférer |
| 4b. `carto-dag-import` | `lieu_inclusion` (+ création `structure_administrative` minimale si SIRET inconnu + asso) | Plus complexe : le SIRET fourni par mednum-cli devient l'employeur, à créer/réutiliser via `ON CONFLICT (siret) DO NOTHING` |
| 4c. `coop-import` | `structure_administrative` + `lieu_inclusion` + asso + les **2** affectations | Le plus complexe : 4 tables touchées, garde temporelle V064 (`updated_at_coop`) à adapter en `updated_at_coop` côté `structure_administrative` |

En parallèle : refonte de `personne-similarities-merge` (split en logique
employeuse vs lieu, ou maintien d'un seul DAG qui gère les 2 nouvelles
tables d'affectations).

**Diff attendu après chaque DAG** :
- Compteurs spécifiques à la source (`edited_by`) cohérents avec un run normal
- Pas de fuite : un run carto ne doit pas modifier des lignes employeuses idposte
- Rattachement MIN : **0 changement** (les utilisateurs MIN sont rattachés
  par `siret`, pas par les DAGs)

**Durée** : 4 semaines (1 par DAG + tampon)
**Risque** : moyen-élevé sur 4c (coop)
**Rollback** : commit revert + restoration des données via `basederef.custom`
si la prod a été touchée.

## Phase 5 — Bascule des consommateurs

**Objectif** : passer chaque vue / loader sur les nouvelles tables.

**Étapes (parallélisables)** :
- `api.carto` : nouvelle version qui lit
  `lieu_inclusion ⋈ asso ⋈ structure_administrative ⋈ personne_affectations_lieu ⋈ personne_affectations_emploi`
- `api.get_carto_mediateur` : même refonte
- `api.get_mediateur` (RPC consommé par Coop) : **doit produire un payload
  structurellement identique** (`structures_employeuses[]`, `lieux_activite[]`)
- `api.aidants_connect` : pareil
- **MIN** (repo séparé `min/`, **même équipe**, déployé conjointement) :
  - `PrismaLieuxInclusionNumeriqueLoader` → lit `lieu_inclusion`
  - `PrismaStructuresEmployeusesCoopLoader` → lit `structure_administrative`
    (renommer ce loader → `PrismaStructuresAdministrativesCoopLoader` ?
    à voir au moment de la MR MIN)
  - Vue `min.personne_enrichie` → refondue (rejoint
    `personne_affectations_emploi` pour `structure_administrative_id`)
  - Vue `min.postes_conseiller_numerique_synthese` → rejoint
    `structure_administrative` au lieu de `main.structure`
  - `PrismaStructureRepository` côté écriture : la création depuis MIN
    écrit dans `structure_administrative` (avec `source='min'`)

**Ordre de déploiement jour J** (à confirmer au moment de la fenêtre) :
- *Scénario 1* — dataspace + MIN déployés simultanément. Fenêtre courte.
- *Scénario 2* — dataspace d'abord, MIN ensuite via la vue de compat
  `main.structure_v_compat` qui permet à l'ancien code MIN de continuer
  à tourner pendant la transition.

**Diff attendu** :
- Nb lignes `api.carto` : **identique** à 0 près (15 168 → 15 168)
- Nb personnes éligibles `api.get_carto_mediateur` : identique
- Nb lignes `api.aidants_connect` : identique (18 368)
- **Rattachement MIN** : invariant clé. Le nombre d'utilisateurs/membres
  rattachés par SIRET doit être **strictement identique**. Si ça bouge,
  on a perdu des données.

**Durée** : 2-3 semaines (incluant la modif MIN)
**Risque** : moyen (modifs MIN + vues api.* + coordination jour J)
**Rollback** : la vue `main.structure_v_compat` reste active, on peut
re-pointer les consommateurs dessus sans toucher au schéma.

**Bascule du rapport `carto_integration`** :
Le rapport `scripts/rapport_carto_integration.py` (un des 5 alimentant
`rapport_all.sh`) mesure la qualité du pipeline carto → base. Après phase 4
carto, seules les 2 premières métriques ont basculé sur le nouveau modèle :

| Métrique | Source post-phase-4 |
|---|---|
| `total` | `import.carto` (inchangé) |
| `matchees` | `import.carto.lieu_inclusion_id IS NOT NULL` ✅ basculée V082 |
| `rejetees` | `import.carto.lieu_inclusion_id IS NULL` ✅ basculée V082 |
| `sans_adresse` | `main.structure` (legacy) — **à basculer phase 5** vers `main.lieu_inclusion` |
| `sans_coordonnees` | `api.carto` — bascule automatique via refonte de la vue |
| `visibles_avant_filtre` | `main.structure` — **à basculer phase 5** |
| `visibles_apres_filtre` | `api.carto` — bascule automatique |
| `sans_affectation` | `main.structure` + `main.personne_affectations` — **à basculer phase 5** vers `lieu_inclusion` + `personne_affectations_lieu` |
| `uniquement_ac` | idem — **à basculer phase 5** |
| `mediateurs_inactifs` | idem — **à basculer phase 5** |
| `au_moins_un_actif` | idem — **à basculer phase 5** |

En transition (phases 4 → 5) les 7 compteurs legacy continuent de mesurer
l'état historique de `main.structure` + `main.personne_affectations`, qui
restent alimentés par les DAGs non encore refondus (aidants-connect, coop).
C'est cohérent : ces compteurs gardent leur sens jusqu'à ce que phase 5
bascule tous les consommateurs et que phase 6 droppe la legacy.

## Phase 5.5 — Validation finale (avant DROP)

**Objectif** : confirmer que la refonte a atteint ses objectifs avant
de passer le point of no return de la phase 6. Si une vérification
échoue ici, **on rollback** (vue de compat + revert + resync) au lieu
de DROP.

**Quand** : après la bascule complète des consommateurs (phase 5),
avant la phase 6.

### Vérification 1 — Cas test Loir-et-Cher (le doublon emblématique)

Cas mesuré en phase 0 : SIRET `22410001600019` (DEPARTEMENT DU LOIR ET
CHER) apparaissait en **2 lignes** dans `main.structure` :
- id 60149 (`edited_by=carto`) : "Conseil Départemental cité administrative"
  → 3 affectations `lieu_activite/coop` actives + 1 membre MIN + 2 utilisateurs MIN
- id 170189 (`edited_by=coop`) : "Departement du Loir et Cher"
  → 6 affectations `structure_emploi/coop` actives

Après refonte, vérifier que ce SIRET donne **1 seule** `structure_administrative`
+ **1 `lieu_inclusion`** lié par asso, en préservant tous les rattachements :

```sql
-- 1.1 Une seule structure_administrative pour ce SIRET
SELECT COUNT(*) AS nb_admin_pour_siret
FROM main.structure_administrative
WHERE siret = '22410001600019';
-- Attendu : 1

-- 1.2 Un seul lieu d'inclusion "cité administrative" rattaché à l'employeuse
SELECT l.id, l.nom, sa.siret, sa.denomination_sirene
FROM main.lieu_inclusion l
JOIN main.lieu_inclusion_structure_administrative lisa ON lisa.lieu_id = l.id
JOIN main.structure_administrative sa ON sa.id = lisa.structure_administrative_id
WHERE sa.siret = '22410001600019';
-- Attendu : 1 ligne, nom = "Conseil Départemental cité administrative"
--           denomination_sirene = "DEPARTEMENT DU LOIR ET CHER"

-- 1.3 Les 6 affectations employeuses Coop sont préservées
SELECT COUNT(*) AS nb_affectations_emploi
FROM main.personne_affectations_emploi pae
JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
WHERE sa.siret = '22410001600019'
  AND pae.est_active
  AND pae.source = 'coop';
-- Attendu : 6

-- 1.4 Les 3 affectations lieu Coop sont préservées
SELECT COUNT(*) AS nb_affectations_lieu
FROM main.personne_affectations_lieu pal
JOIN main.lieu_inclusion l ON l.id = pal.lieu_id
JOIN main.lieu_inclusion_structure_administrative lisa ON lisa.lieu_id = l.id
JOIN main.structure_administrative sa ON sa.id = lisa.structure_administrative_id
WHERE sa.siret = '22410001600019'
  AND pal.est_active
  AND pal.source = 'coop';
-- Attendu : 3

-- 1.5 Membre MIN "departement-41-41" rattaché à la structure_administrative
SELECT sa.siret, sa.denomination_sirene
FROM min.membre m
JOIN main.structure_administrative sa ON sa.id = m.structure_id
WHERE m.id = 'departement-41-41';
-- Attendu : 1 ligne avec siret = '22410001600019'

-- 1.6 Les 2 utilisateurs MIN gestionnaires_structure rattachés à la même structure
SELECT COUNT(*) AS nb_users_min
FROM min.utilisateur u
JOIN main.structure_administrative sa ON sa.id = u.structure_id
WHERE sa.siret = '22410001600019'
  AND u.role = 'gestionnaire_structure';
-- Attendu : 2 (les deux gestionnaires du Conseil départemental)
```

→ Si **toutes ces 6 requêtes sortent les valeurs attendues**, le cas
Loir-et-Cher est OK. Si une seule échoue, **on n'avance pas en phase 6**.

### Vérification 2 — Plus de doublons SIRET (globalement)

```sql
SELECT siret, COUNT(*) AS nb_doublons
FROM main.structure_administrative
WHERE siret IS NOT NULL
GROUP BY siret
HAVING COUNT(*) > 1;
-- Attendu : 0 ligne. La contrainte UNIQUE(siret) garantit ça, mais on
--          vérifie aussi qu'aucune fusion n'a "raté" en cours de route.
```

### Vérification 3 — Rattachement MIN ↔ SIRET inchangé

L'invariant clé : **chaque utilisateur/membre MIN doit pointer sur une
structure ayant le même SIRET qu'avant la refonte**.

```sql
-- Nb utilisateurs MIN rattachés à un SIRET valide (= baseline 1 494)
SELECT COUNT(*) AS users_min_avec_siret
FROM min.utilisateur u
JOIN main.structure_administrative sa ON sa.id = u.structure_id
WHERE sa.siret IS NOT NULL;

-- Nb membres MIN rattachés à un SIRET valide (= baseline 2 153)
SELECT COUNT(*) AS membres_min_avec_siret
FROM min.membre m
JOIN main.structure_administrative sa ON sa.id = m.structure_id
WHERE sa.siret IS NOT NULL;

-- SIRETs distincts portant des utilisateurs/membres MIN
-- (peut diminuer légèrement si des doublons SIRET étaient comptés
--  séparément avant : c'est OK, mais ça doit rester cohérent)
SELECT
  (SELECT COUNT(DISTINCT sa.siret) FROM min.utilisateur u
   JOIN main.structure_administrative sa ON sa.id = u.structure_id
   WHERE sa.siret IS NOT NULL) AS sirets_distincts_utilisateurs,
  (SELECT COUNT(DISTINCT sa.siret) FROM min.membre m
   JOIN main.structure_administrative sa ON sa.id = m.structure_id
   WHERE sa.siret IS NOT NULL) AS sirets_distincts_membres;
```

À comparer avec la baseline `snapshots/phase0_baseline_2026-05-21/structures.json` :
les compteurs `utilisateurs_avec_structure_siret_renseigne` et
`membres_avec_structure_siret_renseigne` doivent rester **strictement
identiques** (≥ baseline ; un + signifie qu'on a résolu des cas en 0.5.b,
un − signifie qu'on a perdu des rattachements → alerte).

### Vérification 4 — Invariants consommateurs API

```sql
-- api.carto : doit retourner ≈ 15 168 lignes (baseline phase 0)
SELECT COUNT(*) FROM api.carto;

-- api.carto avec médiateurs : ≈ 6 399
SELECT COUNT(*) FROM api.carto
WHERE mediateurs IS NOT NULL
  AND jsonb_typeof(mediateurs) = 'array'
  AND jsonb_array_length(mediateurs) > 0;

-- api.aidants_connect : 18 368 lignes (baseline), toutes avec structure_employeuse
SELECT
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE structure_employeuse IS NOT NULL) AS avec_struct
FROM api.aidants_connect;
```

### Vérification 5 — Diff global via `rapport_all.sh`

Le filet de sécurité ultime : un diff complet contre la baseline phase 0.

```bash
DATABASE_URL=postgresql://... scripts/rapport_all.sh diff snapshots/phase0_baseline_2026-05-21
```

Lignes acceptables :
- `main.structure` : `0` lignes (table supprimée à terme — mais à ce stade
  encore présente derrière la vue compat, donc compteur égal à baseline + variations DAG)
- `main.personne_affectations` : idem
- Compteurs personne / rattachement MIN : **strictement identiques** ou explicables
  par des runs DAG normaux entre baseline et bascule
- Compteurs api.* : identiques à 0 près (les vues lisent maintenant le
  nouveau modèle mais doivent produire le même résultat)

→ Toute déviation hors marge normale = on **rollback** avant phase 6.

### Verdict

| Vérif | Résultat | Décision |
|---|---|---|
| 1 (Loir-et-Cher 6 sous-requêtes) | toutes passent | ✓ |
| 2 (0 doublon SIRET) | ✓ | |
| 3 (rattachement MIN) | identique baseline | ✓ |
| 4 (api.* compteurs) | identique baseline | ✓ |
| 5 (rapport_all diff) | aucun écart inattendu | ✓ |

**Toutes ✓ → on peut enchaîner la phase 6 (DROP).**

**Une seule échoue → ROLLBACK** : revert des MRs DAG/MIN, vue compat
réactivée si nécessaire, on investigue, on corrige, on re-valide.

**Durée** : 1-2 jours (exécution des checks + investigation si rouge)
**Risque** : faible si phases 1-5 ont bien suivi les compteurs intermédiaires

## Phase 6 — Cleanup final (point of no return)

> ✅ **FAIT** : `main.structure` et `main.personne_affectations` supprimées par
> V148 (2026-07-30) ; résidus (`min.structure`, `old_structure_id`,
> `api.structures`, réplique `personne_affectations_lieu_legacy`) par V177
> (2026-09-30).

**Objectif** : supprimer l'ancien modèle.

**Migrations** :
- `DROP VIEW main.structure_v_compat` (si encore en place)
- `DROP TABLE main.structure CASCADE` (et avec ça partent les éventuelles
  orphelines résiduelles qu'on aurait laissées en phase 0.5)
- `DROP TABLE main.personne_affectations CASCADE`
- Renaming éventuels des FKs côté tables annexes (`main.contrat`,
  `main.poste`, etc.) si elles pointaient sur `main.structure`
- Mise à jour `CHANGELOG.md` + `CHANGELOG-metier.md`
- Update des rapports : adapter `rapport_comptage.py` et `rapport_structures.py`
  pour pointer sur les nouvelles tables (sinon les compteurs cassent au prochain
  run)

**Diff attendu** :
- `main.structure` : N → 0 (table supprimée — adaptation rapport_comptage requise)
- `main.personne_affectations` : N → 0
- Toutes les autres métriques : 0 changement (sinon régression)

**Durée** : 1 semaine
**Risque** : faible mais **irréversible** sans `basederef.custom` à jour
**Rollback** : restore depuis dump. Aucun rollback partiel possible une
fois `DROP TABLE` exécuté en prod.

## Récap synthétique

| Phase | Quoi | Durée | Risque | Réversible ? |
|---|---|---|---|---|
| 0 | Baseline + métriques | ✅ fait | - | - |
| **0.5** | **Nettoyage données (16 023 orphelines + 25 structures sans SIRET)** | **1-2 sem** | **faible-moyen** | **oui (pg_restore)** |
| 1 | Schéma cible vide | 2-3 j | faible | oui |
| 2 | Peuplement initial | 1 sem | faible-moyen | oui |
| 3 | DAG idposte | 1 sem | moyen | oui (revert + resync script) |
| 4 | DAGs AC, carto, coop | 4 sem | moyen-élevé | oui (revert + resync script) |
| 5 | Consommateurs (api + MIN, même équipe) | 2-3 sem | moyen | oui (vue compat) |
| **5.5** | **Validation finale (avant DROP)** | **1-2 j** | **faible** | **oui** |
| 6 | DROP ancien | 1 sem | faible | **non** |

Stratégie : **big bang strict** (cf section "Stratégie de déploiement" en
haut) — le code de toutes les phases est développé et validé en pré-prod,
puis déployé sur prod en une fenêtre coordonnée avec MIN.

**Total estimé : 11-15 semaines** pour un dev plein temps (validation
finale incluse). Plutôt 3-4 mois calendaires avec coordination MIN.

## Décisions encore ouvertes à trancher

_Toutes les décisions structurantes ont été prises (cf section
"Décisions tranchées" ci-dessous). Reste des choix opérationnels à
prendre au moment de l'exécution (ex : ordre de déploiement jour J)._

## Décisions tranchées

- **Préservation des antennes via `denomination_antenne`** (2026-05-25) :
  V073 ne fusionne plus DISTINCT ON `siret` mais DISTINCT ON `(siret, nom)`.
  Une nouvelle colonne `denomination_antenne` (sur `structure_administrative`)
  identifie la sous-structure quand un SIRET porte plusieurs entités
  opérationnelles (pattern "grand réseau" : Emmaüs Connect, Reconnect Groupe
  SOS, Petits Débrouillards, Hypra, Science Tech & Société…). Contrainte
  d'unicité passée à `UNIQUE NULLS NOT DISTINCT (siret, denomination_antenne)`
  (pgsql 15+). `denomination_antenne` = nom legacy si plusieurs noms pour
  ce SIRET, sinon NULL (entité unique). Pour les SA sans SIRET (assos
  nationales), `denomination_antenne = nom legacy` toujours, pour respecter
  l'unicité. Justification métier : les conventions Conseiller Numérique
  sont signées avec le SIRET du siège, mais les contrats de travail le
  sont avec les antennes — sémantiquement distinctes. Sans ce mécanisme,
  V073 fusionnait 255 lignes legacy en 104 SA → perte de -151 structures
  conventionnées vs prod. Volume post-modif : ~11 200 SA dont ~5 400 avec
  denomination_antenne non-NULL. Migrations impactées : V068 (schéma), V073
  (populate), V078/V079/V080/V085/V086 (FK migrations — nouveau mapping
  par `old_main_structure_id` direct + fallback `(siret, nom)` via
  `COALESCE(sa.denomination_antenne, ms.nom) = ms.nom`).

- **Schéma SIRET/RIDET côté `structure_administrative`** (2026-05-21) :
  colonnes **séparées** `siret VARCHAR(14)` + `ridet VARCHAR(10)`, chacune
  UNIQUE nullable. Justification : formats CHECK différents → 2 contraintes
  plus simples, lecture self-documenting, indexation séparée. Aucune
  occurrence RIDET dans la donnée actuelle (mesure phase 0) mais le
  support est prévu d'emblée pour la Nouvelle-Calédonie / Polynésie.

- **SIRET NULL accepté sur `structure_administrative`** (2026-05-21) :
  pas de CHECK `(siret IS NOT NULL OR ridet IS NOT NULL)`. Justification :
  ~13 structures historiques MIN (assos nationales, organismes sans SIRET
  établi : APF France handicap, Conseil national du numérique, La Coop Num…)
  + cas résiduels après best-effort SIRENE. L'unicité reste garantie dès
  qu'un identifiant externe est posé (`siret`, `ridet`, `structure_coop_id`,
  `_tp_id`, `_ac_id`, `_cartographie_nationale_id` — tous UNIQUE). Pour
  les rares cas totalement sans identifiant, l'unicité est gérée par
  convention UI (alerte côté MIN) et le `similarities-merge` aval.
  → Conséquence : la phase 0.5.b devient **best effort, non bloquante**.
  → Conséquence : la décision ouverte "Que faire des cas non résolus" est
  caduque — on les garde tels quels en `structure_administrative` sans SIRET.

- **Contact JSONB côté `lieu_inclusion`** (2026-05-21) : **conservé**.
  C'est l'usage natif (coordonnées publiques anonymes : telephone, courriels,
  site_web). Sémantiquement distinct du modèle V047 "personne nommée".
  97 % des structures lieux n'ont que ces clés génériques dans leur JSONB.
  Ce n'est pas une dette V047 — c'est un choix sémantique.

- **Contact JSONB côté `structure_administrative`** (2026-05-21) : **conservé
  en héritage**, V047 reste non close par cette refonte. Pendant la
  population (phase 2) :
  - mixtes : scission du JSONB (clés nom/prenom → employeuse, clés
    coords → lieu)
  - pures employeuses avec coords génériques uniquement (129 cas) →
    NULL (jetées, pas de valeur métier)
  - pures employeuses avec nom/prenom (903) → JSONB copié
  La fermeture V047 (migration des nom/prenom JSONB → `main.contact` +
  correction des DAGs qui régressent) reste à faire dans un chantier
  dédié post-refonte.

- La table d'asso V047 `main.contact_structure` est **renommée**
  `main.contact_structure_administrative` en phase 2 et sa FK pointe désormais
  vers `structure_administrative(id)`. 4 313 lignes préservées.

- **Stratégie de déploiement : big bang strict** (2026-05-21) — pas de
  double écriture dans les DAGs. Tout est développé et validé en pré-prod
  (`basederef.custom` local + `dataspace_test` via CI/CD), puis déployé
  sur prod en une fenêtre coordonnée avec MIN. Conditions de réussite :
  pré-prod fidèle, CI/CD avec verdict basé sur `rapport_all.sh diff`,
  dump prod frais juste avant la bascule, script de resync ancien ← nouveau
  prêt à servir en cas de rollback intermédiaire (avant phase 6).

- **MIN modifié dans le même chantier** (2026-05-21) : ce n'est pas une
  coordination cross-équipe, MIN fait partie du périmètre. Reste à choisir
  au jour J entre le scénario 1 (déploiement dataspace + MIN simultanés)
  ou le scénario 2 (dataspace d'abord, MIN ensuite via la vue de compat
  `main.structure_v_compat`). Décision opérationnelle, pas structurelle.

- **Renommage `structure_employeuse` → `structure_administrative`** (2026-05-21) :
  le terme "employeuse" était trop réducteur. Cette entité légale
  (identifiée par SIRET ou RIDET) peut **employer** des médiateurs,
  **bénéficier de subventions** (FNE pour les départements porteurs de
  gouvernance), **porter une gouvernance** (départementale, régionale,
  intercommunale), **héberger des lieux d'inclusion**. Le nom
  `structure_administrative` couvre l'ensemble de ces rôles.
  Cohérence : tables associées renommées en conséquence :
  - `personne_affectations_employeuse` → `personne_affectations_emploi`
    (la relation reste "emploi", la cible est administrative)
  - `lieu_inclusion_structure_employeuse` → `lieu_inclusion_structure_administrative`
  - `contact_structure_employeuse` → `contact_structure_administrative`

## Quick wins suggérés avant la phase 1

- ✅ **`rapport_carto_integration.py` étendu** (2026-05-21) pour supporter
  `--snapshot`/`--depuis-snapshot`/`--avant`/`--apres`. `rapport_all.sh`
  traite désormais les 5 rapports uniformément (plus de "diff manuel jq").
- ✅ **Script `scripts/audit_orphelines_fk.py`** (2026-05-21) — phase 0.5.a
  prête. Liste les 16 023 vraies orphelines + breakdown par `edited_by`.
  Output CSV utilisable comme input direct pour la migration Flyway 0.5.c.

## Next — chantiers post-refonte

Une fois la refonte clôturée (phase 6 mergée), plusieurs chantiers
restent à mener pour finir d'assainir le modèle. Ils ne sont pas dans
le périmètre de ce projet mais sont rendus possibles / nécessaires
par lui.

### N1. Fermeture V047 — drop du JSONB `structure_administrative.contact`

**Pourquoi** : pendant cette refonte on a *conservé* la colonne `contact`
JSONB sur `structure_administrative` en héritage (cf Décisions tranchées).
Elle contient ~903 référents nommés (`nom`, `prenom`) qui devraient être
dans `main.contact` + `main.contact_structure_administrative`. C'est la dette
V047 qui n'a jamais été close — et que cette refonte n'a pas terminé
non plus.

**Travail à faire** :
1. **Migrer** les ~903 cas `structure_administrative.contact ? 'nom'` (ou `'prenom'`) vers `main.contact` (avec `nom`, `prenom`, `email` issu de `courriels`, `telephone`) + asso dans `main.contact_structure_administrative`. Migration Flyway one-shot.
2. **Corriger les DAGs en régression** qui écrivent encore du `nom`/`prenom` dans le JSONB :
   - `id-poste` (36 cas observés en phase 0) : ne devrait écrire que dans la table normalisée, mais des résidus existent
   - `coop` (25 cas) : à diagnostiquer (probablement un fallback historique)
   - MIN `app_python` (894 cas via `PrismaStructureRepository.updateContactReferent`) — c'est l'écriture principale, à refondre côté MIN
3. **Migrer les coordonnées génériques** (telephone/courriels/site_web sur employeuse, ~1 192 cas) — décider si elles ont une valeur métier ou si on les jette comme on l'a fait en phase 2 pour les 129 pures employeuses.
4. **`DROP COLUMN structure_administrative.contact`** — point of no return de la fermeture V047.
5. Mettre à jour `api.aidants_connect`, `api.get_mediateur` et les vues dataviz qui pourraient encore lire le JSONB côté employeuse.

**Estimation** : 2-4 semaines. À cadrer dans un doc dédié quand on l'attaquera.

### N2. Audit des coordonnées sur `lieu_inclusion`

Une fois le modèle stabilisé, vérifier que le JSONB côté `lieu_inclusion`
reste cohérent à travers les sources (Coop, Carto, MIN) — notamment que
les keys `telephone`/`courriels`/`site_web` ne divergent pas entre ce que
chaque source pose et ce qu'`api.carto` expose.

### N3. Réintégration de `main.contact_structure_administrative` dans l'écriture des DAGs

Aujourd'hui seul `id-poste` écrit dans la table normalisée. Coop et AC
pourraient aussi alimenter `main.contact_structure_administrative` si des
référents nommés sont disponibles côté source. À voir si pertinent.

### N4. Nettoyage des scripts de migration one-shot

> ✅ **Vérifié le 2026-09-30** : `resync_legacy.py` et `main.structure_v_compat`
> n'existent plus. Les `*_populate_*.sql` sont les migrations Flyway V073-V077 :
> **à conserver** (Flyway valide l'historique des migrations appliquées). Reste
> éventuel : le dossier `snapshots/` (baselines des phases 0-1).

Une fois la refonte stabilisée :
- Suppression des scripts `*_populate_*.sql` (one-shot)
- Suppression du script `resync_legacy.py` (rollback)
- Suppression de la vue `main.structure_v_compat` (si encore présente)

### N5. Déprécier `structures-similarities-merge` et `personne-similarities-merge`

Ces deux DAGs (~1070 lignes au total) étaient indispensables dans l'ancien
modèle où `main.structure` mélangeait deux concepts : ils faisaient le
matching fuzzy par SIRET / coop_id / carto_id / cn_pg_id / etc. et
fusionnaient les doublons cross-source.

Dans le nouveau modèle, leur rôle disparaît en pratique :

**Raison 1 — déduplication absorbée par les contraintes UNIQUE** :
- `structure_administrative_siret_ukey` (les SIRET ne peuvent plus exister
  en doublon côté SA)
- `structure_administrative_structure_coop_id_ukey` /
  `structure_administrative_structure_ac_id_ukey` /
  `structure_administrative_structure_tp_id_ukey`
- `lieu_inclusion_carto_id_ukey`
- `lieu_inclusion_structure_coop_id_ukey`
- `personne_cn_pg_id`, `personne_aidant_connect_id`, `personne_coop_id`

Mesure 2026-05-22 (phase 4 terminée) : **0 doublon résiduel** côté SA, LI,
ou personne sur tous ces axes.

**Raison 2 — pas de critère fiable pour marier SA ↔ LI quand l'asso manque** :
La table `lieu_inclusion_structure_administrative` peut être sous-alimentée
dans les cas suivants :
- SA importée par idposte/AC, LI importée par carto, qui décrivent la
  même entité physique mais sans `structure_coop_id` partagé.

On a mesuré 1 462 paires SA + LI partageant un SIRET sans asso, et 3 193
LI ayant un SIRET dans `import.carto` mais aucune asso. **Mais le SIRET
côté LI est généralement pollué par le portage** (une mairie ou une asso
chapeau partage son SIRET avec N antennes / lieux gérés). Marier
automatiquement SA ↔ LI par ce SIRET reviendrait à lier une entité légale
à des lieux qui ne sont pas son siège — incorrect dans la majorité des cas.

Les seuls cas où le mariage automatique reste fiable (coop_id partagé)
sont déjà traités par `coop-dag` refondu (B++).

**Cas résiduels manuels** :
- Deux SA distinctes décrivant la même entité avec des SIRET divergents
  par erreur de saisie.
- Deux LI sans coop_id ni carto_id partageant nom+adresse.

Trop marginaux et trop risqués pour un DAG automatique — mieux traités
par scripts ponctuels supervisés.

**Action** : ✅ FAIT (2026-07-30). Triggers retirés du dernier DAG où ils
étaient actifs (aidants-connect) et DAG files `*-similarities-dag.py`
supprimés. Les vues `dataviz.structure_similarities` /
`dataviz.personne_similarities` (matviews de détection) restent à dropper
en migration avec les vues opendata. Reliquat fonctionnel côté personnes :
cf [[N13]].

### N6. Sonder les consommateurs réels de `api.structures` (vue de compat V087)

> ✅ **FAIT** (V177, 2026-09-30) : seul `postgrest_anct_dev` (tests dev, jeton
> expiré le 2025-12-31) y avait accès — vue et rôle supprimés. Data Inclusion
> consomme `api.carto`.

**Décision prise sans connaître les consommateurs précis** (le 2026-05-22) :
on a opté pour une vue de compat (option 2) qui combine
`structure_administrative` + `lieu_inclusion` via la table d'association,
plutôt qu'une vue SA-centric pure (option 1) qui aurait dédoublonné par
SIRET (28 651 → 7 916 lignes, soit -72 %).

**Limites connues** :
- Le payload n'est pas bit-à-bit identique au legacy. Comptages, ordre des
  lignes et nullité des champs SIRENE pour les purs lieux d'inclusion ont
  changé.
- Aucun audit n'a été fait des usages réels côté Coop / ANCT. On sait
  seulement que `postgrest_anct_dev` a SELECT sur la vue.

**Investigations à mener avant phase 6 (DROP main.structure)** :
1. Sortir un échantillon de la vue **avant** (legacy) et **après** (compat)
   pour les 3 grands cas :
   - SA pure (employeuse) — payload `nom = denomination_sirene`, SIRET non NULL
   - LI pure (lieu) — payload `nom = li.nom`, SIRET NULL
   - mixte — payload `nom = li.nom`, SIRET non NULL
2. Identifier les consommateurs HTTP de l'API `/structures` (logs PostgREST,
   réseaux GitLab, contacts métier).
3. Pour chaque consommateur identifié, vérifier :
   - Que les champs SA suffisent (SIRET, RNA, denomination_sirene, code APE,
     etat_administratif, categorie_juridique).
   - Que la dénormalisation du `nom` (LI.nom prioritaire, fallback
     denomination_sirene) ne casse pas leur logique.
   - Que la déduplication par SIRET (côté SA) ne change pas leur usage
     (typiquement : si quelqu'un faisait GROUP BY SIRET, le comportement
     reste OK).
4. Si un consommateur dépend du comportement legacy spécifique (nb lignes
   exact, structures sans SIRET avec un `nom` quelconque…), ajuster la
   vue ou ajouter une vue dédiée.

Cette tâche **doit être faite** avant le DROP main.structure de phase 6 —
sinon on bascule à l'aveugle et on prend le risque de casser un usage
non identifié.

### N7. Régression `dataviz.*` — refonte technique livrée (2026-05-27)

**Statut** : refonte technique livrée par V094 (2026-05-27). Le décompte
initial mentionnait 10 vues ; après audit, 8 vues étaient effectivement
concernées (les 2 vues `*_similarities` n'existent plus localement — DAG
similarities-merge déprécié).

**Vues refondues (V094)** :
- `dataviz.structures` — UNION 3 cas (mixte SA+LI / SA pure / LI pure),
  calque sur V087 ; 29 081 lignes (vs 28 651 legacy).
- `dataviz.poste` + `dataviz.poste_pseudonymisee` — FK `poste.structure_id`
  pointe sur SA depuis V078 ; nom_structure via
  `COALESCE(denomination_antenne, denomination_sirene)`.
- `dataviz.lieux_inclusion_numerique` — côté LI (filtre
  `structure_cartographie_nationale_id IS NOT NULL` conservé), agrégats
  conseillers via `paf_lieu` ; 16 189 lignes.
- `dataviz.personne` + `dataviz.personne_pseudonymisee` — `paf_emploi`
  pour structure employeuse (SA) + `paf_lieu` pour zonages QPV/FRR ;
  28 141 lignes.
- `dataviz.structures_employeuses` — SA + `paf_emploi` + agrégats LI
  ramenés via asso (mediateurs_en_activite, France Services) ;
  11 638 lignes.
- `dataviz.zonages` — comptage SA pour `nbr_structures`, LI pour
  `nbr_lieux`/`accompagnements`/`personnes` ; 3 893 lignes.
- `dataviz.personnes_accompagnements` — fix sémantique : legacy comparait
  `adresse.id` avec `structure.id` par bug ; corrigé via `li.adresse_id`.

**Approche** : refonte aveugle (sans accès Metabase). Le contrat (noms +
types de colonnes) est préservé ; comportement (volumes, IDs, ordre)
peut marginalement différer.

**Décision (2026-05-27)** : pas d'accès BDD Metabase côté dev → on
**assume le risque** de régression visuelle sur les dashboards.
Justification : usage faible en l'état, correctifs post-déploiement
acceptables. Pas de sondage préalable.

**Post-déploiement (à surveiller)** :
- Remontées éventuelles côté équipe métier sur un dashboard cassé →
  patcher la vue concernée à la demande.
- Cas le plus probable de surprise : `dataviz.structures` dédoublonne
  désormais par SIRET (côté SA) là où le legacy gardait N lignes par
  SIRET partagé. Si un dashboard faisait un comptage brut sans
  GROUP BY SIRET, le chiffre peut baisser.

**Bloquant pour phase 6 (DROP main.structure)** : non — les vues sont
indépendantes du legacy.

### N8. Double comptage potentiel sur les agrégats LI ⋈ SA via l'asso

Le schéma `lieu_inclusion_structure_administrative` autorise N:N — un
lieu_inclusion peut être rattaché à plusieurs structure_administrative.
La contrainte `UNIQUE (lieu_id, structure_administrative_id)` empêche
les doublons d'asso, mais ne contraint **pas** la cardinalité de l'asso
côté lieu (un lieu peut avoir 0, 1, 2, N structures associées).

**Conséquence pour les requêtes qui font `JOIN lieu_inclusion ⋈ asso ⋈ SA`** :
un lieu rattaché à 2 SA apparaît 2 fois dans le résultat. Selon
l'agrégat, ça peut produire un comptage faussé.

Mesure actuelle : phase 2 (V075) a peuplé l'asso avec 1 585 lignes
(uniquement les "mixtes" 1:1). En pratique la cardinalité reste 1:1 pour
la quasi-totalité aujourd'hui. Mais **ce n'est pas garanti par le schéma**.

**Vu côté MIN (PrismaLieuxInclusionNumeriqueLoader)** :
- `totalLieuxInclusionNumerique` (sans JOIN_SA_VIA_ASSO) : OK, pas
  de doublon.
- `lieuxInclusionNumeriqueSecteurPublic` (avec JOIN) : un lieu rattaché
  à 2 SA en 7% est compté 2 fois.
- `repartitionLieuxParCategorieJuridique` (avec JOIN) : un lieu peut
  apparaître dans plusieurs buckets.

**Vu côté dataspace (V087 api.structures + V089 api.carto)** :
- `api.structures` (V087, vue de compat) : le `JOIN asso ⋈ SA` produit
  intentionnellement N lignes par SA. Si demain un LI a 2 SA, le LI
  apparaît 2 fois. Comportement "comme le legacy" mais à surveiller.
- `api.carto` (V089) : SIRET récupéré via `LEFT JOIN asso ⋈ SA`. Avec
  2 SA sur le même lieu, on aurait 2 lignes pour le même carto_id.
  Vérifié 2026-05-22 : 0 LI a 2 SA, mais à monitorer.

**Préco** : pour les requêtes avec le JOIN SA, préférer
`COUNT(DISTINCT l.id)` au lieu de `COUNT(*)`, et si on veut un seul SIRET
par lieu, prendre la première SA (DISTINCT ON / LATERAL LIMIT 1).

**À faire** :
1. Auditer les compteurs en pré-prod sur `basederef.custom` :
   `api.structures`, `api.carto`, `PrismaLieuxInclusionNumeriqueLoader`.
   Comparer avec / sans la déduplication.
2. Si impact non négligeable, refactorer les requêtes vers
   `COUNT(DISTINCT)` ou ajouter un `LATERAL LIMIT 1` sur l'asso.
3. Ajouter un test d'invariant qui détecte les LI multi-SA et alerte.

### N9. Audit qualité SIRET sur `lieu_inclusion`

Constat 2026-05-22 : les SIRET fournis par les sources côté lieu (carto
notamment, via `import.carto.pivot`) sont souvent **le SIRET du porteur**
(mairie, asso chapeau) et pas un SIRET propre au lieu d'inclusion. Cas
classique : 30 antennes France Services portées par une mairie héritent
toutes du SIRET de la mairie sans qu'elles aient leur propre entité légale.

Conséquence : on ne peut pas marier automatiquement SA ↔ LI par SIRET
(cf N5) sans risquer de lier une entité légale à des lieux qui ne sont
pas son siège.

**Investigation à mener** :

1. Pour chaque LI ayant un SIRET (via `import.carto.pivot` ou autre),
   récupérer l'adresse SIRENE (via API INSEE ou la table SIRENE cache)
   et comparer avec l'adresse du LI.
2. Si adresse SIRENE ≈ adresse LI (= même code postal + nom_commune,
   éventuellement nom_voie) : le SIRET désigne le lieu lui-même
   (= mixte vrai), on peut marier.
3. Si adresse SIRENE ≠ adresse LI : SIRET de porteur, à ignorer pour
   le mariage automatique.

Le résultat de cet audit débloquera N5 (mariage automatique fiable
quand l'adresse SIRENE correspond) et améliorera la qualité des
sorties `api.carto` (`pivot` correct au lieu de `'00000000000000'`
pour les lieux qui ont une vraie identité légale).

### N10. Fusion de structures côté coop — propagation des activités

Côté coop-numerique, une fusion de structures (2 lignes `structures` qui
représentent en fait la même entité fusionnées en une seule) peut survenir
suite au cleanup que Marc mène en parallèle (cf [[project-coop-conception-partagee]]).
Côté dataspace, on doit alors :
- détecter la fusion (la `structure_coop_id` du loser disparaît,
  ses activités/affectations migrent vers le winner) ;
- propager : ré-attribuer `activites_coop.lieu_id` et
  `personne_affectations_*.{structure_administrative_id, lieu_id}`
  vers la SA/LI du winner ;
- côté source, éventuellement supprimer la SA/LI loser une fois vidée
  (ou la garder comme "alias historique" via une table de redirection).

Pistes à arbitrer :
- **Webhook coop → dataspace** : la coop notifie le merge avec l'ID
  loser et l'ID winner. On applique la propagation in-process. Le plus
  propre, mais demande un dev côté coop.
- **Algo de détection à l'import** : structures_ingest repère qu'une
  `structure_coop_id` n'apparaît plus dans le fetch courant ET qu'une
  autre porte ses utilisateurs/affectations → propose un merge (avec
  validation manuelle ou seuil de confiance).

À cadrer avec Marc une fois la phase 4c stabilisée.

### N11. Drop final des tables legacy `main.structure` et `main.personne_affectations`

> ✅ **FAIT** : V148 (2026-07-30), côté MIN PR #1823. Suite : V177 supprime
> `min.structure` et les colonnes `min.membre/utilisateur.old_structure_id`.

Après la refonte phase 5, ces deux tables ne sont **plus écrites** par les DAGs
(`carto-dag-import`, `coop-dag`, `aidants-connect-dag`) ni par MIN. Elles
survivent uniquement pour les consommateurs historiques, le temps qu'ils
basculent sur les vues de compat ou sur les nouvelles tables :
- `dataviz.*` (cf [[N7]] — régression à auditer)
- Anciens consommateurs `api.structures` (cf [[N6]] — sondage en cours)
- Scripts d'audit / exports CSV qui pointent encore `main.structure.*`

Plan de cleanup, une fois N6 + N7 soldés :
1. Vérifier qu'aucun job/DAG n'écrit/lit ces tables (`grep -r main.structure
   main.personne_affectations` dans dataspace, MIN, coop-numerique, dataviz).
2. Vérifier qu'aucune FK externe ne pointe encore vers elles (`SELECT *
   FROM information_schema.table_constraints WHERE constraint_type =
   'FOREIGN KEY' AND ...`). Côté MIN, V085/V086 ont déjà remappé
   `min.membre` et `min.utilisateur` vers `structure_administrative`.
3. Migration Flyway V09x dataspace : `DROP TABLE main.structure CASCADE;`
   `DROP TABLE main.personne_affectations CASCADE;` (avec `U` counterpart).
4. Côté MIN : retirer les models `main_structure` et `personne_affectations`
   du `prisma/schema.prisma` (actuellement `@@ignore` pour silencer
   `prisma migrate dev`). Régénérer le snapshot via `pnpm db:sync-dataspace`.

**Ce qui ne doit PAS être droppé** dans cette opération :
- Colonnes `main.personne.is_referent_ac` / `is_visible` /
  `updated_at_ac` / `updated_at_coop` / `updated_at_idposte` → alimentées
  par les DAGs ingest aidants-connect / coop / idposte (timestamps de
  dernière synchro par source, flags métier dataspace).
- Colonne `main.activites_coop.beneficiaires` → agrégats nominatifs
  alimentés par le DAG coop (cf. commentaire SQL en base).

Ces colonnes ne sont pas consommées par MIN mais restent **actives** côté
dataspace. Elles sont déclarées dans `prisma/schema.prisma` de MIN
uniquement pour neutraliser les faux diffs de `prisma migrate dev`.

### N12. Challenger l'assertion `typeDeStructure: ''` côté MIN

Dans `PrismaMesInformationsPersonnellesLoader` (MIN), le champ
`typeDeStructure` renvoie désormais une chaîne vide pour un utilisateur
"Gestionnaire structure". Raison technique : la colonne `typologies`
vivait sur `main.structure` legacy, elle est passée sur
`main.lieu_inclusion` lors de la refonte — `main.structure_administrative`
ne porte pas de typologie.

Or l'utilisateur connecté est rattaché à une **SA** via `min.utilisateur.structure_id`,
pas à un lieu. Donc côté MIN, "mes informations personnelles" n'a plus
de typologie directe à afficher.

**À challenger** : est-ce le comportement attendu côté UX ?
- Si oui : confirmer la valeur vide et adapter l'écran "Mes informations"
  (ne plus afficher le champ ou afficher "—").
- Si non : récupérer la typologie via un lieu_inclusion associé à la SA
  (via `main.lieu_inclusion_structure_administrative`). Attention : N:N,
  une SA peut héberger plusieurs LI avec des typologies différentes.
  Décision produit nécessaire (typologie "principale" ? agrégation ?
  liste ?).

Référence test :
`min/src/gateways/PrismaMesInformationsPersonnellesLoader.test.ts` —
assertion `typeDeStructure: ''` à valider avec PO/UX.

### N13. Réconciliation personnes AC ↔ Coop supervisée

**Contexte** : la suppression de `personne-similarities-merge` (2026-07-30,
avec `structures-similarities-merge`) laisse un reliquat fonctionnel que
le nouveau modèle ne couvre pas. Contrairement aux structures (SIRET),
une personne n'a **pas de clé naturelle cross-source** : les contraintes
UNIQUE (`aidant_connect_id`, `cn_pg_id`, `coop_id`) ne dédupliquent
qu'intra-source.

**Ce qui est couvert** :
- Coop ↔ CN : jointure déterministe dans le flux coop (la coop fournit
  `conseiller_numerique_id` / `cn_pg_id`).
- Le stock historique : 844 personnes multi-sources (AC + coop/CN sur la
  même ligne), fusionnées par l'ancien DAG, préservées.

**Ce qui ne l'est plus** : AC ↔ (CN/Coop). L'ingest AC
(`etl/load/aidants_connect.py`) matche uniquement par `aidant_connect_id` —
un nouvel aidant également médiateur coop crée une seconde ligne
`main.personne`. NB : cette capacité était déjà morte de facto depuis la
bascule (la matview de détection lisait `main.personne_affectations` ⋈
`main.structure` legacy, figées) — le DAG tournait sur données périmées.

**Impact mesuré (2026-07-30, dataspace_dev)** : 17 796 personnes AC-only,
dont ≤ 875 homonymes exacts (nom + prénom normalisés) d'une personne
coop/CN — majorant, sans la garde « même commune » qu'appliquait l'ancien
DAG. Conséquences : label « Aidant Connect » manquant sur des médiateurs
`api.carto` (V101 exige l'affectation AC active sur la même ligne
personne) et double comptage modéré dans les stats personnes/dataviz.
Pas de doublon d'affichage dans `api.carto` (dédup par personne V101).

**Forme cible** : PAS un merge automatique nocturne (le matching flou
auto crée des dégâts silencieux, cf #1468 côté SA). Plutôt :
1. Un rapport de détection reconstruit sur le nouveau modèle
   (`personne_affectations_emploi` ⋈ `structure_administrative` ⋈
   `main.adresse` pour la garde commune).
2. Une fusion **supervisée** consommant ce rapport — sur le modèle de
   l'UI doublons SA côté MIN (winner/loser + audit), ou script supervisé
   réutilisant `audit.personne_merge_log`.

À prioriser si le métier remonte des doublons de médiateurs ou des labels
AC manquants sur la cartographie.

## Pointeurs

- Cadrage modélisation : [`refonte-structure-modelisation.md`](refonte-structure-modelisation.md)
- Métriques et baseline : [`refonte-structure-metriques.md`](refonte-structure-metriques.md)
- Pistes de simplification cross-source : [`flux-globaux.md`](../../architecture/flux-globaux.md) §7
- Snapshot baseline : `snapshots/phase0_baseline_2026-05-21/`
- Orchestrateur métriques : `scripts/rapport_all.sh`
