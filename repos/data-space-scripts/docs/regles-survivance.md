# Règles de survivance — quand deux sources se contredisent, qui gagne ?

> Étape 3 de la feuille de route ([approche-data/08](../approche-data/08-feuille-de-route.md)),
> fiche [04 MDM](../approche-data/04-mdm-reconciliation.md). Rétro-ingénierie du code réel
> (2026-07-29) : ce document décrit les règles **telles qu'elles sont**, involontaires
> comprises — pas telles qu'on les voudrait. Il est la spécification de fait des ingest ;
> toute évolution du code qui change une règle doit mettre à jour ce tableau.
>
> **Statut : à faire valider par le métier.** Les points marqués ⚠ sont des règles
> probablement involontaires, découvertes par la rétro-ingénierie.

## Les mécanismes de survivance en jeu

Il n'y a plus de module central de réconciliation (`merge.py` / `deduplicate.py` cités par
la doctrine n'existent plus). La survivance est décidée à quatre endroits :

| Mécanisme | Où | Effet |
|---|---|---|
| **Upserts des ingest** | coop-dag.py, aidants-connect-dag.py (+ etl/load/aidants_connect.py), schema-idPoste.py, carto-dag-import.py | chaque source écrit « ses » champs, avec `ON CONFLICT`, `COALESCE`, gardes de fraîcheur |
| **Gardes de fraîcheur par source** | colonnes `updated_at_coop` / `updated_at_ac` / `updated_at_idposte` (V064), `updated_at` lieu (V115/V116) | une source ne se met à jour que si sa donnée est plus récente que **sa propre** dernière écriture |
| **Fusion de doublons (similarities)** | personne-similarities-dag.py, structures-similarities-dag.py (V031/V032/V041), journal `audit.*_merge_log` (V037) | matching fuzzy + fusion winner/loser — **déclenchés uniquement par le DAG aidants-connect** (triggers coop / carto / idposte commentés depuis la refonte, phases 3.b–4c) |
| **Rechargements complets** | schema-idPoste.py (`TRUNCATE RESTART IDENTITY` sur poste, contrat, formation, subvention) | idposte est source de vérité exclusive : tout est reconstruit à chaque run |

Ordre quotidien observé des écrivains : coop (06h11) → carto (23h11) → sirene-backfill
(04h00) ; idposte à la demande (dépôt manuel) ; AC quotidien.

---

## Entité PERSONNE (`main.personne`)

Clés de rapprochement entre sources : `coop_id` (coop), `aidant_connect_id` (AC),
`cn_pg_id` = `conseiller_numerique.id_pg` côté coop = `id_cn` côté idposte,
`conseiller_numerique_id`. Les cross-références sont posées par `_guard()`
(coop-dag.py:612-625) : jamais d'écrasement d'un id déjà posé, jamais de collision avec
une autre personne.

| Champ | Qui gagne | Règle exacte | Réf |
|---|---|---|---|
| nom, prenom | coop et AC écrasent (si plus frais que leur propre dernière écriture) ; **idposte ne remplace jamais** un nom déjà en base (`COALESCE(p.nom, EXCLUDED.nom)`) | garde V064 par source | coop-dag.py:627-630 ; aidants-connect-dag.py ; schema-idPoste.py:290-292 |
| contact (JSONB email/tél) | **personne ne perd** : fusion additive `p.contact \|\| s.contact` par les 3 sources — une clef posée n'est jamais supprimée, la dernière source à écrire une même clef la remplace | ⚠ un email corrigé côté source ne chasse pas l'ancien si la clef diffère | coop-dag.py:629 ; schema-idPoste.py:291 |
| is_visible (consentement carto publique) | **coop, exclusivement** (choix exprimé par la personne) ; NULL = visible (`IS DISTINCT FROM FALSE`, V062) | AC/idposte n'y touchent jamais | etl/core/coop.py:163 |
| is_mediateur | coop le calcule (présence objet `mediateur`) ; **idposte force TRUE** pour tout CN ; la tâche `force_coordinators_to_mediators` force TRUE pour tout coordinateur | ⚠ trois écrivains, dernier passé gagne — pas de conflit observé en pratique | schema-idPoste.py:289 ; coop-dag.py:2192-2207 |
| is_coordinateur | coop, exclusivement | présence objet `coordinateur` | etl/core/coop.py |
| deleted_at / deleted_by | coop, exclusivement (`suppression` API) ; `deleted_at = max(ancien, nouveau)`, `deleted_by` accumule | AC/idposte ne suppriment jamais | coop-dag.py:639-647 |
| champs `*_ac` (profession, nb_accompagnements, is_referent…) | AC, exclusivement, si plus frais (garde `updated_at_ac`) | | aidants-connect-dag.py:105-129 |
| cn_pg_id / coop_id / conseiller_numerique_id | premier arrivé, protégé par `_guard()` (pas d'écrasement, pas de collision) | | coop-dag.py:612-625 |

### Affectations (qui travaille où)

Table `personne_affectations_emploi` / `_lieu`, clef `(personne, structure/lieu, source)` :
**chaque source possède ses lignes**, il n'y a pas de conflit direct — l'arbitrage se fait
en lecture (vue `min.personne_enrichie`, V044).

| Lien | Source qui fait foi | Règle |
|---|---|---|
| emploi d'un CN | **idposte** (`est_active` = existence d'un contrat sans rupture) ; les `emplois` coop d'un CN sont **ignorés** | schema-idPoste.py:398-421 ; ⚠ si idposte est en retard, l'emploi d'un CN récent n'existe nulle part |
| emploi d'un non-CN | coop (reset `est_active=FALSE` de toutes ses lignes puis upsert — les affectations disparues du payload s'éteignent) | coop-dag.py:1903-1947 |
| emploi côté AC | AC, upsert simple (`est_active` = actif côté AC) | aidants_connect.py:672-717 |
| lieu d'activité | coop, exclusivement — se fier au champ `fin` (pas `suppression`) | coop-dag.py:1737-1819 |
| coordination médiateur↔coordinateur | coop, exclusivement, additif (`ON CONFLICT DO NOTHING`) | coop-dag.py:2090 |
| en lecture (`min.personne_enrichie`) | « CN en poste » = affectation idposte active ; « médiateur en poste » = affectation idposte **ou** coop active ; « aidant en poste » = affectation AC active | V044 |

---

## Entité STRUCTURE

Deux tables depuis la refonte 2026 : `main.structure_administrative` (entité légale,
clef naturelle `(siret, denomination_antenne)`) et `main.lieu_inclusion` (lieu physique,
clef `structure_cartographie_nationale_id`, `structure_coop_id`).

### `main.lieu_inclusion` — la carto nationale fait foi, si plus fraîche

| Champ | Qui gagne | Règle exacte | Réf |
|---|---|---|---|
| nom, présentation, horaires, services, typologies, contact… | **carto**, si `date_maj` carto > `updated_at` du lieu (garde V115/V116) — sinon l'existant (souvent coop) est conservé | le `contact` est **remplacé** en bloc (pas fusionné, contrairement à personne) | carto-dag-import.py integration_lieux (~l.238-440) |
| adresse_id / geom | carto via BAN ; si le géocodage échoue, l'ancienne adresse est conservée (`COALESCE`) | | idem |
| mediateurs_en_activite, emplois (compteurs) | **coop, exclusivement** — jamais écrasés par carto | | coop-dag.py |
| visible_pour_cartographie_nationale | présence dans le fichier carto du jour : présent → TRUE, absent → FALSE (cycle de vie) | | carto-dag-import.py |
| structure_coop_id | extrait de l'id carto (`Coop-numérique_<uuid>` standalone) ; ⚠ ~1 263 ids composés non extraits → lien coop absent | | etl/core/carto.py |

### `main.structure_administrative` — premier arrivé conserve, on complète les trous

| Champ | Qui gagne | Règle exacte | Réf |
|---|---|---|---|
| siret, ridet, denomination_antenne | figés (clef d'unicité) — jamais écrasés | | V068 |
| structure_tp_id / structure_coop_id / structure_ac_id | premier arrivé, jamais écrasé (UNIQUE + `WHERE … IS NULL`) ; rattachement idposte par `(siret, adresse)` + similarité de nom, siège en repli | | schema-idPoste.py:1159-1183 |
| denomination_sirene, etat_administratif, code APE, catégorie juridique | **complétés, jamais écrasés par NULL** (`COALESCE`) par idposte et par le backfill SIRENE ; ⚠ **pas de garde de fraîcheur : dernier écrivain gagne** entre les deux | | schema-idPoste.py ; sirene-backfill-dag.py:167-190 |
| adresse_id | ⚠ idposte **remplace sans condition** si sa propre adresse BAN est trouvée | | schema-idPoste.py |

⚠ Point rouge : `sirene-backfill-dag.py:175` met à jour **`main.structure`** (table
legacy), pas `structure_administrative` — l'entité refondue ne reçoit l'enrichissement
SIRENE qu'au fil des ingest carto/idposte. À trancher (phase 3.d de la refonte).

### `main.adresse` — immuable, on enrichit les trous

| Écrivain | Règle |
|---|---|
| carto | `INSERT … ON CONFLICT DO NOTHING` — la première adresse insérée est figée |
| idposte | `DO UPDATE` avec `COALESCE` sur `code_ban`, `clef_interop`, `geom` uniquement — remplit les trous, ne remplace jamais |

⚠ Conséquence : une correction d'adresse côté BAN ou carto n'est **jamais** répercutée sur
une adresse existante.

### Postes, contrats, formations, subventions

**idposte, exclusivement** : `TRUNCATE … RESTART IDENTITY` puis rechargement complet à
chaque run (schema-idPoste.py:1346-1367). Aucune autre source n'y écrit. ⚠ Les `id` de ces
tables changent à CHAQUE run — aucun consommateur ne doit les stocker (cf. audit
identifiants, fiche 04).

---

## Fusion de doublons (similarities) — règles winner/loser

Matching (V031/V041 personnes, V032 structures) : similarité trigram pg_trgm sur noms
normalisés (`unaccent(lower(trim))`), bloquée par `code_insee` (personnes) ou
`(siret, adresse)` identiques (structures). **Seuil : paramètre de DAG
`similarity_threshold`, défaut 1.0** (= quasi-exact) — pas de table de configuration
(chantier suivant), pas de zone grise ni de revue humaine.

| Sujet | Règle de survivance |
|---|---|
| winner personne | la ligne au `updated_at` le plus récent (V031:88-95) |
| winner structure | hiérarchie de sources : **idposte (TP) > coop > AC** (V032:40-54) ; pas de règle applicable → pas de fusion |
| champs du perdant | `COALESCE(winner, loser)` (le winner garde ses valeurs, le loser comble les trous) ; contacts fusionnés ; arrays unis |
| is_visible fusionné | **restrictif** : FALSE si l'un des deux est FALSE (le refus de visibilité survit à la fusion) |
| visible_pour_cartographie_nationale | inclusif : TRUE si l'un des deux est TRUE |
| affectations | `est_active = winner OR loser`, doublons purgés |
| le perdant | **supprimé** après remap de toutes les FK ; snapshots avant/après dans `audit.personne_merge_log` / `audit.structure_merge_log` (V037) — la défusion reste théoriquement possible via ces snapshots, pas outillée |

⚠ État réel : ces fusions ne sont déclenchées **que par le DAG aidants-connect**
(aidants-connect-dag.py:549-559). Les triggers depuis coop, carto et idposte sont
commentés depuis la refonte (« phases 3.b / 4c ») : les doublons créés par ces trois flux
ne sont plus résorbés automatiquement.

---

## Réponses aux questions métier types

- **« Carto et coop donnent deux adresses différentes pour le même lieu : laquelle est
  affichée ? »** Celle de la source la plus récente au sens de `date_maj` carto vs
  dernière écriture : carto ne gagne que si son `date_maj` est postérieur. Si le géocodage
  BAN de carto échoue, l'adresse précédente reste.
- **« Une personne demande à être masquée dans la coop : peut-elle réapparaître via une
  autre source ? »** Non pour le drapeau (`is_visible` n'appartient qu'à coop, et une
  fusion de doublons conserve le refus). Incident historique 9d19646 : le drapeau était
  mal lu, corrigé.
- **« Qui décide qu'un conseiller numérique est en poste ? »** idposte (existence d'un
  contrat sans rupture), jamais coop — même si la coop affiche un emploi.
- **« Une correction manuelle survit-elle à la nuit ? »** Non garanti : aucune règle
  `override_humain` n'existe (cf. fiche 04, piège n°2). Les champs à fusion additive
  (contact) conservent la valeur, les champs écrasés par les gardes de fraîcheur non.

## Chantiers ouverts issus de ce document

1. Valider ce tableau avec le métier ; trancher les ⚠ (notamment : SIRENE backfill sur la
   table legacy, adresses immuables, similarities éteintes pour coop/carto/idposte).
2. Seuils de matching en configuration (étape 3, chantier suivant).
3. Crosswalk pérenne (étape 3) : les clés naturelles nécessaires existent toutes.
4. Priorité de survivance `override_humain` pour les corrections MIN (fiche 04 §4).
