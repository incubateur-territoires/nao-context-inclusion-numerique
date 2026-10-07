# 05 — De l'ETL pandas/CSV à l'ELT SQL déclaratif (dbt)

← [Retour au document central](README.md)

> **DÉCISION (2026-07-31) : dbt Core est retenu** pour porter la transformation
> silver → gold. L'alternative « SQL pur » (fin de fiche) est écartée. La mise en
> œuvre n'est PAS lancée : elle est conditionnée aux trois prérequis de la section
> [Prérequis avant le premier modèle](#prérequis-avant-le-premier-modèle).

## Le concept

**ETL** (Extract-Transform-Load) : transformer *hors* de la base (ici : pandas + CSV temp),
puis charger. **ELT** (Extract-Load-Transform) : charger le brut dans la base, puis
transformer *dans* la base, en SQL.

L'état de l'art a massivement basculé vers l'ELT quand les données tiennent dans un moteur
SQL — ce qui est exactement notre cas (tout est déjà dans PostgreSQL, les volumes sont de
l'ordre de 10⁴–10⁶ lignes). Faire sortir les données de Postgres pour les transformer en
pandas et les remettre dans Postgres est un antipattern : on perd le typage, les
contraintes, la requêtabilité des états intermédiaires, et on paie des sérialisations CSV.

**dbt** (data build tool) est l'outil standard de la couche T : chaque modèle est un
fichier SQL `SELECT`, dbt gère le DAG de dépendances entre modèles, les matérialisations
(table/vue/incrémental), les **tests**, et génère la **documentation + lineage**.

## Ce que dbt apporterait concrètement ici

| Aujourd'hui | Avec dbt |
|-------------|----------|
| Transformations pandas dispersées dans `etl/transform/`, états en CSV `/tmp` | Un modèle SQL par table, états intermédiaires requêtables dans `staging` |
| Ordre des traitements câblé dans les DAGs Airflow | DAG de dépendances déduit automatiquement des `ref()` entre modèles |
| Qualité vérifiée par rapports manuels | `unique`, `not_null`, `relationships`, tests SQL custom — exécutés à chaque `dbt build`, bloquants |
| Documentation inexistante ou dans les têtes | `dbt docs` : catalogue navigable + **lineage graph** généré (répond aussi aux fiches 06 et 07) |
| Impact d'une MR sur les données invisible | CI : `dbt build` sur échantillon + diff des résultats |
| Logique métier illisible pour un profil data/analyste | SQL relu par n'importe quel profil data, y compris non-dev |

Important : **dbt ne remplace pas Airflow**. Airflow garde l'orchestration, l'extract
(APIs externes, fichiers), les enrichissements par API (SIRENE, géocodage IGN — qui
restent du Python, `SireneBatch`/`GeocodeurBatch` sont bien conçus pour ça). dbt prend la
couche transform SQL. L'intégration se fait via **Astronomer Cosmos** (chaque modèle dbt
devient une tâche Airflow visible, avec retries individuels) ou un simple
`BashOperator("dbt build")` pour commencer.

## Ce qui reste en Python

Tout n'a pas vocation à passer en SQL :

- **Extract** : appels d'API, pagination, auth → Python/Airflow.
- **Enrichissements externes** : SIRENE, géocodage BAN/IGN → Python (batch existants).
  Leur *résultat* atterrit dans des tables `staging`, que dbt consomme.
- **Fuzzy matching** (rapidfuzz) : le calcul des similarités reste en Python, mais il
  **écrit ses scores dans une table** (déjà le cas : `similarities-*`) ; les décisions de
  fusion et la survivance (fiche 04) deviennent des modèles SQL lisibles.

Règle de partage simple : *si c'est du set-based (jointures, filtres, agrégats, dédup par
clé) → SQL/dbt ; si c'est de l'algorithmique ou de l'I/O externe → Python.*

## Architecture cible

```
Airflow DAG
├── extract (Python)          → source.*            (bronze, fiche 01)
├── enrichissements (Python)  → staging.sirene_*, staging.geocodage_*
├── similarités (Python)      → staging.similarites_*
└── dbt build (Cosmos)
    ├── staging/   : stg_coop__personnes.sql, stg_carto__lieux.sql...   (typage, nettoyage)
    ├── intermediate/ : int_structures_matchees.sql, int_survivance.sql (réconciliation)
    ├── marts/     : structures.sql, personnes.sql, postes.sql          (→ main)
    └── tests      : schema.yml (unique, not_null, relationships, custom)
```

Coexistence avec l'existant : Flyway garde les schémas, contraintes, vues `api`/`dataviz`
et tout le DDL "plateforme" ; dbt gère le *contenu* de `staging` et `main`. Frontière à
documenter clairement pour éviter les conflits (dbt ne doit pas toucher aux tables sous
contrainte Flyway sans convention — typiquement dbt écrit des tables `staging` et alimente
`main` via des modèles incrémentaux `ON CONFLICT`).

Le changement de fond que porte cette architecture : aujourd'hui chaque DAG de source
écrit le gold dans la foulée de son fetch (le gold = résidu de l'ordre des runs, cf
[fiche 18](../chantiers/survivance-gold/cartographie-ecritures-gold.md)) ; avec dbt, les DAGs de sources s'arrêtent
au silver, et **une transformation unique, à son propre rythme, dérive le gold depuis
l'état courant de TOUS les silvers** — matching et survivance appliqués sur l'ensemble,
résultat indépendant de l'ordre des fetchs. Elle n'attend pas que « tous les silvers
soient à jour » (les sources ont des rythmes incompatibles : quotidien coop/AC vs
millésime idposte) : un silver est en permanence « le dernier état connu de sa source ».

## Prérequis avant le premier modèle

Trois manques rendent aujourd'hui impossible un gold dérivé des silvers. Les traiter
AVANT d'écrire le premier modèle de réconciliation — sinon dbt ne ferait que réencoder
l'implicite actuel dans un autre langage :

1. **Règles de survivance validées métier** ([fiche 04 §3](mdm-reconciliation.md),
   étape 3 de la [feuille de route](../chantiers/plateforme-data/feuille-de-route.md)). Les règles *constatées*
   sont documentées ([fiche 18](../chantiers/survivance-gold/cartographie-ecritures-gold.md)) et condensées en
   tableau de décision arbitrable ([fiche 20](../chantiers/survivance-gold/decisions-survivance.md), rédigée
   2026-07-31) ; reste l'arbitrage métier ligne à ligne. Ce tableau validé est la
   spécification des modèles `intermediate/` de survivance.
2. **Crosswalk d'identifiants** ([fiche 04 §1](mdm-reconciliation.md)). Les ID
   pivots actuels sont des séquences non reproductibles : un gold reconstruit
   changerait tous les ID exposés à MIN et à l'API. Le crosswalk
   `(uuid_pivot, source, source_key)` — pérenne, hors du cycle des runs — est ce qui
   rend le gold reconstructible sans casser les consommateurs. L'audit 2026-07-29 a
   confirmé que les clés naturelles nécessaires existent toutes. Spec de conception
   rédigée ([fiche 21](../chantiers/crosswalk/conception-crosswalk.md), 2026-07-31) — 7 points de décision
   en attente de validation.
3. **Éditions humaines MIN traitées comme une source** ([fiche 04 §4](mdm-reconciliation.md)).
   MIN écrit directement le gold (fusions, canonisations) ; une transformation qui
   redérive le gold écraserait ces corrections à chaque run. Prérequis : capturer les
   overrides humains comme une source à part entière (`source.min__evenements` V124 en
   est l'embryon), avec priorité de survivance maximale (`override_humain`). Spec de
   conception rédigée ([fiche 22](../chantiers/overrides-min/conception-overrides-min.md), 2026-07-31) — 5
   points de décision + dépendances côté équipe MIN.

## Stratégie de migration — progressive, flux par flux

**Ne pas faire de big bang.** Le pipeline actuel fonctionne ; la migration se fait par
étranglement (strangler pattern) :

1. **Pilote** : choisir le flux le plus simple (ex. aidants-connect), le migrer de bout en
   bout : `source` → modèles staging dbt → mart. Comparer la sortie avec l'existant
   (`EXCEPT`) jusqu'à iso-résultat, puis basculer.
2. Migrer les autres ingest un par un, même méthode.
3. Migrer la réconciliation en dernier (la plus complexe, et elle bénéficie d'abord du
   travail de documentation des règles de la fiche 04).
4. À chaque flux migré : supprimer le code pandas correspondant (pas de double maintenance).

Alternative minimale si dbt est jugé trop gros : les mêmes principes en SQL pur —
transformations en `CREATE TABLE AS` / procédures versionnées, tests via
`SQLCheckOperator`. On perd les tests déclaratifs, la doc et le lineage générés, mais
c'est déjà un progrès majeur vs CSV temp. dbt reste recommandé : l'écosystème (tests,
docs, CI) est ce qui transforme la pratique, pas juste le SQL.

## Par où commencer

1. ~~Décision d'équipe : dbt Core (recommandé) vs SQL pur.~~ **Fait — dbt Core retenu
   (2026-07-31).**
2. Traiter les [prérequis](#prérequis-avant-le-premier-modèle) : tableau de décision
   de survivance validé métier, crosswalk, doctrine des overrides MIN.
3. Setup dbt minimal pointant sur la base dev + profil CI (PostGIS éphémère, comme
   `test_migration`).
4. Pilote sur un flux simple, iso-résultat prouvé par diff.
5. Cosmos pour l'intégration Airflow quand il y a >1 flux migré.

## Pièges connus

- **Migrer sans figer le comportement** : sans diff systématique avec l'existant, on
  introduit des régressions silencieuses en croyant refactorer.
- **Modèles dbt monolithiques** : un modèle de 800 lignes reproduit le problème du script
  pandas de 800 lignes. Découper (staging → intermediate → mart), c'est le lineage qui
  fait la lisibilité.
- **Deux vérités** : pendant la migration, l'ancien et le nouveau chemin ne doivent jamais
  écrire la même table cible.
- **PostGIS** : dbt gère bien PostGIS (types geometry dans les modèles), mais les macros
  de tests génériques ignorent la géométrie — prévoir quelques tests custom (validité des
  geom, SRID).

## Références

- dbt Core — documentation officielle (best practices : staging/intermediate/marts)
- Astronomer Cosmos — intégration dbt ↔ Airflow (skill `data:cosmos-dbt-core` disponible dans ce repo)
- *The Analytics Engineering Guide* (dbt Labs) — le manifeste du rôle "analytics engineer"
