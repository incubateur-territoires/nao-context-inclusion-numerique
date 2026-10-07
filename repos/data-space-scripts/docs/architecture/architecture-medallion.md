# 01 — Architecture en couches (medallion)

← [Retour au document central](README.md)

## Le concept

L'architecture "medallion" (popularisée par Databricks, mais applicable à tout entrepôt,
PostgreSQL inclus) organise les données en trois couches de raffinement croissant :

| Couche | Nom classique | Contenu | Propriété clé |
|--------|---------------|---------|---------------|
| **Bronze** | raw / source | Données brutes telles que reçues des sources | **Immuable, append-only, horodatée** |
| **Silver** | staging / cleaned | Données typées, nettoyées, normalisées, dédupliquées *par source* | **100 % reconstructible depuis bronze** |
| **Gold** | marts / main | Données réconciliées inter-sources, modèle métier final | Exposée aux consommateurs |

L'idée fondamentale : **la valeur d'un entrepôt est proportionnelle à sa capacité à être
reconstruit**. Si tout l'aval peut être recalculé depuis le brut, alors un bug de
transformation n'est jamais une perte de données — c'est juste un recalcul.

## Les trois principes associés

### 1. Immutabilité du brut

On n'écrase **jamais** ce qu'une source a envoyé. Chaque extraction est un nouvel
enregistrement horodaté. Cela permet de répondre à des questions impossibles aujourd'hui :

- "Qu'est-ce que coop nous a envoyé le 12 mars ?" (audit, litige avec une source)
- "Depuis quand ce champ est-il vide ?" (diagnostic de régression)
- "Rejouer l'ingestion du 12 mars avec le code corrigé" (correction rétroactive)

### 2. Idempotence

Rejouer un traitement N fois produit exactement le même résultat. Concrètement :

- Les écritures aval sont des `INSERT ... ON CONFLICT DO UPDATE` ou des `TRUNCATE + INSERT`
  transactionnels, jamais des appends accumulatifs.
- Les identifiants sont **déterministes** (UUID v5 dérivé de la clé source, pas UUID v4
  aléatoire regénéré à chaque run).
- Aucune dépendance à un état externe mutable (fichier temp d'un run précédent, ordre
  d'exécution implicite).

### 3. Reproductibilité temporelle

Pouvoir répondre "quel était l'état de `main` le 1er juin ?" — soit par historisation
(SCD2, voir plus bas), soit par capacité à rejouer le pipeline sur le bronze d'une date donnée.

## État actuel du projet

- `import.{source}__{table}` : écrasé à chaque run → **pas de bronze**. Le schéma `import`
  est en réalité un buffer de travail, pas une couche brute.
- Transformations (`etl/transform/`) : pandas → **CSV dans des répertoires temporaires** →
  `etl/load/`. La couche silver existe conceptuellement mais vit dans `/tmp` : invisible,
  non requêtable, perdue après le run.
- `main` : gold de facto, mais sans provenance ni historique (partiellement compensé par
  `main.audit_trail` V124).
- **La couche `source` append-only existe désormais en base** — c'est le bronze. Mais
  son usage est inégal selon les flux (captures post-transform, consommateurs restés sur
  XCom/CSV) : le pattern d'ingestion cible et l'état de conformité par flux sont dans la
  [fiche 15](pattern-flux-reference.md).

## Mise en place sur ce projet

### Bronze : la couche `source` (spec existante)

Structure type par flux :

```sql
CREATE TABLE source.coop__personnes (
    capture_id      uuid        NOT NULL,   -- identifiant du run de capture
    captured_at     timestamptz NOT NULL,   -- horodatage de l'extraction
    source_key      text        NOT NULL,   -- clé native de la source
    payload         jsonb       NOT NULL    -- enregistrement brut, sans transformation
);
-- Append-only : aucun UPDATE/DELETE accordé aux rôles applicatifs
```

Points d'attention :

- **Capturer avant toute transformation**, y compris le typage : le `payload` est le JSON/CSV
  tel que reçu. Un bug de parsing ne doit pas corrompre le brut.
- Une table de runs (`source.capture_run`) : id, flux, début/fin, statut, volumétrie —
  point d'appui pour l'observabilité (fiche 06).
- Rétention : le brut grossit. Prévoir une politique (ex. garder toutes les captures 90 jours,
  puis 1 par semaine) — mais la décision de purge est une décision de gouvernance, pas un
  `DELETE` de confort.

### Silver : sortir les états intermédiaires de `/tmp`

Remplacer progressivement les CSV temporaires par un schéma `staging` en base :

```
source.coop__personnes  ──(typage, nettoyage, renommage)──►  staging.coop__personnes
                                                                    │
staging.carto__lieux, staging.coop__structures, ...  ──(réconciliation)──►  staging.personnes,
                                                                            staging.structures, ...
                                                                                  │
                                                              (tests qualité, fiche 03)
                                                                                  │
                                                                                  ▼
                                                                               main.*
```

`staging` contient donc deux familles de tables : les tables **par source**
(`staging.{source}__{table}`) et les tables **réconciliées pré-publication**
(`staging.personnes`, `staging.structures`…) — c'est sur ces dernières que s'exécutent
les tests bloquants avant le load en `main` (pattern Write-Audit-Publish, fiche 03).

Bénéfices immédiats : chaque étape est requêtable en SQL, comparable entre deux runs
(`EXCEPT`), testable (fiche 03), et le debugging devient "une requête" au lieu de
"relancer le DAG avec des prints".

### Gold : historisation de `main`

Deux options selon le besoin :

- **SCD Type 2** (slowly changing dimensions) : chaque ligne porte `valid_from` /
  `valid_to` ; l'état courant est une vue `WHERE valid_to IS NULL`. Puissant mais
  intrusif pour les consommateurs.
- **Audit trail** (choix déjà fait : `main.audit_trail`, V124) : `main` reste "état
  courant", l'historique vit à côté en jsonb. Moins requêtable pour de l'analyse
  temporelle, mais suffisant pour l'audit et compatible avec MIN sans refonte.

Recommandation : conserver l'approche audit_trail pour MIN, et si un besoin analytique
temporel émerge ("évolution du nombre de structures par mois"), le servir par des
**snapshots périodiques** en `dataviz` plutôt qu'en complexifiant `main`.
Analyse complète des options d'historisation (types SCD, snapshots, dbt snapshots) :
[fiche 09](historisation-scd.md).

## Pièges connus

- **Bronze "propre"** : la tentation de nettoyer un peu au passage ("juste trimmer les
  espaces"). Non — le bronze est brut ou il ne sert à rien.
- **Silver partiellement en CSV** : une migration à moitié faite donne le pire des deux
  mondes. Migrer flux par flux, complètement.
- **Idempotence testée une fois puis oubliée** : ajouter un test CI "rejouer le DAG deux
  fois → diff vide" (fiche 03).

## Références

- Databricks — *Medallion Architecture* (concept d'origine)
- Maxime Beauchemin — *Functional Data Engineering* (idempotence, immutabilité, reproductibilité — l'article fondateur, par le créateur d'Airflow)
- Kimball — *The Data Warehouse Toolkit* (SCD, modélisation dimensionnelle)

## Exception : sources hébergées dans le même cluster (coop)

Depuis la bascule Prisma de la coop, ses tables (`coop.*`) vivent dans la base de
l'entrepôt. Les trois finalités du bronze (rejouer un run, tracer reçu vs chargé,
auditer l'évolution) sont alors mieux servies par la table source elle-même
(`creation` / `modification` / `suppression`) que par une capture JSON quotidienne
— redondante, et redondante en PII pour les utilisateurs. Décision (V144, V151,
V159 — #1707/#1724) : **pas de couche source ni staging pour le flux coop** ; les
vues `main.*` lisent `coop.*` en direct, et l'identité des lieux est maintenue par
un filet SQL (`etl/load/registre_lieux_coop.py`). Le médaillon complet reste la
règle pour toute source externe au cluster.
