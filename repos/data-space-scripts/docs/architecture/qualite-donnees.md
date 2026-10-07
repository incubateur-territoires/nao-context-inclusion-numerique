# 03 — Qualité de données : tests bloquants, quarantaine, CI data

← [Retour au document central](README.md)

## Le concept

Dans une approche data mature, la qualité n'est pas un rapport qu'un humain lit — c'est un
**ensemble de tests déclaratifs, exécutés automatiquement à chaque run, qui bloquent le
pipeline** quand un invariant est violé. Exactement comme les tests unitaires pour le code :
on ne "vérifie pas à la main que le code marche", on a une CI.

Trois familles de contrôles :

| Famille | Question | Exemple |
|---------|----------|---------|
| **Invariants** (bloquants) | Les données violent-elles une règle absolue ? | Unicité des UUID, SIRET à 14 chiffres, FK valides, pas de personne sans structure |
| **Vraisemblance** (bloquants ou warn) | Les données sont-elles plausibles ? | Volumétrie ±20 % vs run précédent, taux de NULL stable, distribution des départements |
| **Fond métier** (warn + revue) | Les données racontent-elles quelque chose de cohérent ? | Un médiateur actif dans 40 structures, des doublons probables non fusionnés |

Et un principe cardinal : **on ne droppe jamais silencieusement**. Une ligne invalide est
mise en **quarantaine** avec son motif, pas supprimée.

## État actuel du projet

- `scripts/rapport_comptage.py`, `rapport_validation.py`, `rapport_personnes.py` : lancés
  **à la main**, avant/après les runs, par un humain qui compare visuellement. C'est de la
  qualité artisanale : la bonne intuition, le mauvais outillage.
- Les contraintes d'intégrité de `main` (NOT NULL, FK, UNIQUE) sont le seul filet
  automatique — elles arrêtent le load mais **après** que le transform a tourné, avec un
  message PostgreSQL brut, sans contexte métier.
- ~~Les lignes écartées pendant les transformations pandas disparaissent sans trace.~~
  **Réglé (2026-07-30)** : `staging.rejets` existe (section 2) et tous les drops qualité
  identifiés y sont routés (géocodages invalides, skips ingest coop, items AC sans id).
- La CI (`check-dag`, `test-dag`) vérifie que le code se charge, jamais que les données
  produites sont justes.

### Constat 2026-07-31 : pas de validation statique des formats

Révélé par l'incident du premier run AC en stock complet (UniqueViolation
`siret_antenne_ukey`) : les caractéristiques de format d'une donnée (un SIRET = 14
chiffres, un code INSEE = motif départemental, un CP = 5 chiffres…) ne sont **validées
déclarativement nulle part**. La règle « SIRET = 14 chiffres » existe en 4 endroits sans
point de vérité unique, aucun ne produisant de signal exploitable :

| Couche | Ce qui existe | Limite |
|---|---|---|
| Bronze | rien (voulu, capture brute) | un siret `48` entre tel quel |
| Contrats (warn, chaque run) | présence + type JSON simple (`etl/core/contrat.py`) | un siret à 13 chiffres est un `integer` conforme → zéro alerte ; les formats sont en prose `semantique:`, jamais exécutés |
| Transform | regex en dur, éparpillées (`validate_pivot`, `validate_code_insee`…) | retour `None` **silencieux** — pas branché sur `staging.rejets` (le motif `siret_invalide` prévu ci-dessous n'est jamais émis) |
| Gold | CHECK SQL (`siret ~ '^\d{14}$'`, `ridet`, enums, `mois` 1er du mois) | tardif : crashe le DAG au lieu de rejeter la ligne, sans contexte amont |

Impact mesuré (base min, 2026-07-31, dernier stock AC de 8 368 structures) : 16 structures
à siret invalide annulé en silence par `validate_pivot` (13 chiffres — zéro initial perdu
par le typage nombre JSON —, 15 chiffres, ou aberrant) entrent en collision de nom avec des
SA existantes → c'est le crash du run ; 111 autres avec siret valide dupliqué se rattachent
silencieusement sans jamais obtenir de SA.

Chemin naturel (à décider, rien d'implémenté) :

1. Router les invalidations de `validate_pivot` / `validate_code_insee` vers
   `staging.rejets` (motifs `siret_invalide`, `code_insee_invalide`) — la mécanique de
   quarantaine existe, c'est le branchement qui manque.
2. Ajouter une section `regles:` exécutable aux contrats (regex / domaine par champ),
   validée en warn comme le reste de la fiche 02 — un seul point de vérité, les CHECK
   gold restant le filet ultime.

## Mise en place sur ce projet

### 1. Transformer les rapports existants en tests bloquants

Les rapports contiennent déjà les bonnes questions. Les convertir en assertions SQL,
exécutées par une tâche Airflow **entre transform et load** (sur staging) et **après load**
(sur main) :

```sql
-- tests/quality/personnes.sql — chaque requête doit renvoyer 0 ligne
-- test: personne_sans_uuid (bloquant)
SELECT id FROM staging.personnes WHERE uuid IS NULL;

-- test: volumetrie_personnes (bloquant si écart > 20 %)
SELECT count(*) AS n FROM staging.personnes
HAVING count(*) NOT BETWEEN
    (SELECT count(*) * 0.8 FROM main.personne)
AND (SELECT count(*) * 1.2 FROM main.personne);
```

```
transform ──► tests_staging ──► load ──► tests_main ──► (publish api/dataviz)
                   │                          │
                   └── échec → DAG rouge + alerte Mattermost, main intact
```

Point structurant : tant que `tests_staging` échoue, **`main` n'est pas touché**. Les
consommateurs (MIN, API, Metabase) voient des données vieilles mais justes — jamais des
données fraîches et fausses. C'est le compromis correct.

### 2. Table de quarantaine

```sql
CREATE TABLE staging.rejets (
    rejete_at    timestamptz NOT NULL DEFAULT now(),
    flux         text        NOT NULL,   -- 'coop__personnes'
    etape        text        NOT NULL,   -- 'ingest', 'reconciliate'
    motif        text        NOT NULL,   -- 'siret_invalide', 'doublon_ambigu'
    source_key   text,
    payload      jsonb       NOT NULL    -- la ligne écartée, complète
);
```

- Chaque `dropna()` / filtre d'exclusion dans le code d'ingest écrit ses rejets ici.
- Une vue `min` par-dessus permet au **métier** de traiter les rejets (corriger à la
  source, créer une règle) — MIN est l'interface idéale pour ça.
- Métrique à suivre (fiche 06) : taux de rejet par flux. Une hausse = drift source.

### 3. CI data : tester les transformations avant merge

- **Jeu d'échantillon versionné** : quelques centaines de lignes par source, anonymisées
  (le setup `--with-data` pseudonymisé existe déjà — en extraire un échantillon figé).
- Job CI : monter un PostGIS éphémère (comme `test_migration` le fait déjà), rejouer
  extract-fixture → transform → tests qualité. Une MR qui change une règle métier **montre
  son diff de données** dans la CI.
- Test d'**idempotence** : rejouer le pipeline deux fois sur l'échantillon → `EXCEPT` vide
  entre les deux résultats.

### 4. Outillage

Trois niveaux, du plus simple au plus riche — commencer simple :

1. **SQL pur + opérateur Airflow maison** (`SQLCheckOperator` existe nativement) : zéro
   dépendance, suffisant pour 80 % du besoin. **Recommandé pour démarrer.**
2. **Soda Core** : tests déclaratifs YAML (`checks for staging.personnes: row_count > 20000`),
   bon rapport puissance/complexité, s'intègre à Airflow.
3. **Great Expectations** : le plus complet (data docs générées), mais lourd. À ne
   considérer que si Soda montre ses limites.

Si la migration dbt se fait (fiche 05), les tests dbt (`unique`, `not_null`,
`relationships`, tests SQL custom) deviennent le socle naturel — c'est un argument de plus
pour dbt.

## Par où commencer

1. Lister les invariants déjà vérifiés par les 3 rapports manuels → les écrire en SQL.
2. Une tâche `tests_main` en fin de DAG principal, mode warn (alerte Mattermost) 2 semaines.
3. Passer les invariants durs en bloquant ; créer `staging.rejets` et y router les premiers
   filtres d'exclusion.
4. CI data sur échantillon (peut venir plus tard, avec dbt).

## Pièges connus

- **Tests warn éternels** : un warn ignoré 3 mois est un test mort. Chaque warn doit avoir
  une échéance : devenir bloquant ou être supprimé.
- **Seuils de volumétrie trop fins** : ±5 % sur des sources vivantes = fausses alertes =
  alerting ignoré. Commencer large (±20-30 %), resserrer avec l'historique.
- **Tout tester** : 30 tests pertinents valent mieux que 300 tests bruités. Prioriser ce
  qui a déjà causé des incidents (visibilité, doublons, géocodage).

## Références

- dbt tests / Soda Core / Great Expectations (documentation officielle)
- Airflow `SQLCheckOperator`, `SQLColumnCheckOperator`, `SQLTableCheckOperator`
- Concept WAP — *Write-Audit-Publish pattern* (écrire, auditer, puis seulement publier)
