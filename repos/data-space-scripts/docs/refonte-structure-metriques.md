# Métriques de la refonte `main.structure`

> **Statut** : doc d'ouverture du projet. Décrit l'angle d'attaque et les
> compteurs de non-régression utilisés pour valider chaque étape.
>
> **Articulation** :
> - [`refonte-structure-modelisation.md`](refonte-structure-modelisation.md) — cadrage de la refonte (pourquoi, modèle cible, questions ouvertes)
> - [`refonte-structure-plan.md`](refonte-structure-plan.md) — plan d'exécution phase par phase (utilise ce doc-ci pour les invariants attendus)
> - [`flux-globaux.md`](flux-globaux.md) §7 — pistes de simplification cross-source

## Pourquoi des métriques avant tout

La refonte de `main.structure` en `structure_administrative` + `lieu_inclusion`
touche 4 DAGs, 5 vues `api.*`, MIN et sa vue `min.personne_enrichie`, plus
les `*-similarities-merge`. Beaucoup de pièces mobiles, beaucoup d'endroits
où on peut **perdre des données** ou **introduire des doublons** sans s'en
rendre compte.

Au lieu de planifier la migration "en aveugle", on installe d'abord des
**compteurs invariants** : pour chaque concept métier (structures par
catégorie, rattachement MIN, lignes exposées par `api.carto`…), on compte
**avant** et **après** chaque étape. Si le diff sort de la marge attendue,
on rollback et on creuse.

Les compteurs sont **invariants attendus**, pas des analyses exploratoires.
On ne mesure pas "à quel point les noms divergent de la dénomination
SIRENE" — on sait déjà que c'est divergent. On mesure : "combien
d'utilisateurs MIN sont rattachés à une structure avec SIRET ? Si après
refonte ce nombre baisse de 5 %, on a un problème."

## Flow opérationnel

L'idée : reproduire facilement n'importe quel état de la base, et comparer.

```
1. pg_restore basederef.custom (baseline locale)
        ↓
2. rapport_structures.py --snapshot -o snapshots/baseline.json
        ↓
3. <appliquer la modification : migration SQL, bascule DAG, etc.>
        ↓
4. rapport_structures.py --depuis-snapshot snapshots/baseline.json
        ↓
   Si diff inattendu :
     - pg_restore basederef.custom (reset)
     - investiguer / corriger
     - retour à l'étape 3
   Si diff attendu :
     - commiter le delta dans snapshots/
     - passer à l'étape suivante
```

Le dump `basederef.custom` (1 Go) est gitignored — chacun récupère le sien.

## Compteurs implémentés (v1)

Fichier : `scripts/rapport_structures.py`. Sur le modèle de
`rapport_personnes.py` (4 modes : simple / snapshot / depuis-snapshot /
avant-après ; 4 formats : text, json, csv, markdown).

| Section | Compteurs | Pourquoi |
|---|---|---|
| **Totaux** | `main.structure`, `main.adresse` | référence absolue |
| **Catégorie métier** | pures employeuses, pures lieux, mixtes, orphelines | l'invariant principal du projet — chaque structure doit retomber dans la bonne table après refonte |
| **Source d'écriture** | `edited_by`, `source` (origine mednum-cli) | aucune source ne doit "perdre" ses lignes lors de la migration |
| **Identifiants externes** | nb avec `structure_coop_id` / `_tp_id` / `_ac_id` / `_cartographie_nationale_id` / aucun | reconstitution cross-source — chacun de ces compteurs doit rester identique |
| **API Carto** | nb lignes `api.carto`, nb avec médiateurs JSONB non-vide, nb `main.structure` visibles + carto_id | invariant côté consommateur Cartographie |
| **Rattachement MIN** | `min.utilisateur` / `min.membre` avec / sans `structure_id`, avec SIRET / sans SIRET, SIRETs distincts | **invariant clé** : chaque utilisateur / membre MIN doit retomber sur une `structure_administrative` de même SIRET après refonte |

## Baseline actuelle (dataspace_dev, 2026-05-21)

Indicateurs d'entrée pour le projet :

- **44 728** lignes dans `main.structure`
- **5 432** pures employeuses · **17 522** pures lieux · **1 982** mixtes · **19 792** sans aff active ni carto_id (44 %), dont **16 023 vraies orphelines** (aucune FK n'y pointe → suppression sûre phase 0.5.c)
- **15 168** lignes exposées par `api.carto` (6 399 avec médiateurs)
- **1 513** utilisateurs MIN rattachés à une structure (1 494 sur SIRET valide, 19 sans SIRET)
- **2 180** membres MIN tous rattachés (2 153 sur SIRET valide, 27 sans SIRET)

Les compteurs "rattaché à une structure sans SIRET" (19 utilisateurs +
27 membres) correspondent en réalité à **25 structures distinctes**
(beaucoup ont à la fois 1 membre + 1 utilisateur). Par catégorie : 11
communes (résolution SIRENE attendue automatique) + 13 structures
diverses (résolution au cas par cas) + 1 sans membre. À traiter en phase
0.5.b — ces structures ne peuvent pas devenir `structure_administrative`
sans SIRET résolu.

## Compteurs à ajouter quand on en aura besoin

Pas dans v1, mais à garder en tête :

- **Affectations par `type` × `source` × `est_active`** : utile dès qu'on touche au DAG `coop-import` ou aux `*-similarities-merge`.
- **Simulation `api.get_mediateur`** : invariant côté Coop (le RPC qui boucle vers Coop). Probablement à ajouter quand on touchera au DAG coop ou à la vue.
- **Tables `main.contrat` / `main.poste` / `main.formation` / `main.subvention`** : reliées aux structures employeuses idposte. À ajouter quand on touchera au DAG idposte.
- **`api.aidants_connect`** : si ANCT Incub confirme qu'ils consomment.

Ces ajouts viendront au fil des phases. Chaque nouveau compteur sera
documenté ici (ou dans le doc de phase correspondant).

## Convention pour les snapshots versionnés

Les snapshots JSON commités dans `snapshots/` sont des **invariants
historiques** qu'on garde comme référence pour rollback / comparaison.
Nommage proposé :

```
snapshots/<phase>_<jalon>_<YYYY-MM-DD>.json
```

Exemples :
- `snapshots/phase0_baseline_2026-05-21.json` — état initial
- `snapshots/phase1_after_new_schema_2026-06-03.json` — après création des tables
- `snapshots/phase2_after_idposte_2026-06-15.json` — après bascule du DAG idposte

Le diff entre ces snapshots = preuve qu'on n'a pas dérivé. On peut
reconstruire le passé sans la base.
