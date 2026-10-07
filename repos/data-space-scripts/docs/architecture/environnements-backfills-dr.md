# 13 — Environnements, backfills, sauvegarde et reprise

← [Retour au document central](README.md)

## Le concept

Le versant **DataOps** de la plateforme : appliquer aux *données* les disciplines
d'ingénierie que le code a déjà (environnements, promotion contrôlée, reprise sur
incident). Trois sujets distincts mais liés :

| Sujet | Question traitée |
|-------|------------------|
| **Environnements data** | Où teste-t-on des changements de pipeline sans risquer la prod ? Avec quelles données ? |
| **Backfills / re-traitements** | Comment rejouer proprement l'historique après un bug ou une nouvelle règle ? |
| **Sauvegarde & reprise (DR)** | Que perd-on en cas de sinistre, en combien de temps repart-on ? (RPO/RTO) |

Le fil conducteur : dans une plateforme data, **le code et les données ont des cycles de
vie différents**. Le code se teste avec la CI ; un changement de *données* (nouvelle règle
de survivance, backfill) doit pouvoir être **prévisualisé, comparé, puis promu** — pas
appliqué directement en prod en espérant que ça se passe bien.

## État actuel du projet

- **Environnements** : trois connexions existent (`sonum-test-db`, `sonum-dev-db`,
  `sonum-prod-db`) et les migrations passent par dev avant prod (`apply_migration_dev` →
  `apply_migration_prod`) — c'est un vrai pipeline de promotion pour le *schéma*. Mais pour
  les *données* : le dev local repose sur `--with-data` (dump pseudonymisé, fraîcheur non
  garantie), et rien ne définit quand un changement de transformation doit être validé sur
  dev avant d'atteindre prod.
- **Backfills** : pas de mécanisme. Sans couche bronze (fiche 01), rejouer le passé est
  de toute façon impossible — un bug de transformation corrigé aujourd'hui laisse les
  données historiques fausses, sans recours. Les DAGs ne sont pas conçus pour être
  exécutés "à date" (pas de partitionnement par `logical_date`).
- **DR** : les sauvegardes existent vraisemblablement côté hébergeur, mais **du point de
  vue data, rien n'est documenté** : RPO/RTO inconnus, restauration jamais testée, et
  surtout personne n'a écrit *ce qui est reconstructible vs ce qui est irremplaçable*.

## Mise en place sur ce projet

### 1. Doctrine d'environnements data

Formaliser ce que chaque environnement garantit :

| Environnement | Données | Usage | Règle |
|---------------|---------|-------|-------|
| **Local / CI (+ `sonum-test-db`)** | Échantillon versionné, anonymisé, figé | Tests unitaires, CI data (fiche 03), dev de transformation, runs d'essai des DAGs | Reproductible à l'identique par tous ; `sonum-test-db` est jetable |
| **Dev (`sonum-dev-db`)** | Copie récente de prod, pseudonymisée | Validation des migrations (déjà le cas) + **validation des changements de pipeline** avec diff | Rafraîchie régulièrement (mensuel), procédure automatisée |
| **Prod (`sonum-prod-db`)** | Réelles | — | Aucun test, aucune requête exploratoire lourde (rôle `dev_readonly`, fiche 11, pour le debugging) |

La règle qui manque : **tout changement de règle métier dans le pipeline est exécuté sur
dev d'abord, avec un diff quantifié** ("cette MR change 1 240 structures, en voici la
répartition") joint à la MR. C'est la CI data (fiche 03) au niveau environnement complet —
la CI sur échantillon attrape les régressions logiques, le run sur dev montre l'impact réel.

- Automatiser le rafraîchissement de dev (dump prod → pseudonymisation → restore) : une
  procédure manuelle et pénible ne sera pas exécutée, et un dev sur données de 8 mois
  valide dans le vide. L'outillage de pseudonymisation existe (`--with-data`) — le
  planifier (DAG mensuel dédié).

### 2. Backfills : rejouer le passé proprement

Prérequis : la couche bronze horodatée (fiche 01) — sans elle, ce chapitre est théorique.
Avec elle :

- **Concevoir les DAGs pour le re-traitement** : les tâches de transformation prennent la
  date/`capture_id` en paramètre au lieu de supposer "le dernier extract". Airflow le
  prévoit nativement (`logical_date`, backfill par plage de dates) — c'est une convention
  d'écriture des tâches plus qu'un outillage.
- **Procédure de backfill type** (à écrire une fois) :
  1. Identifier la plage affectée (grâce à `pipeline_metrics` / `capture_run`, fiche 06) ;
  2. Rejouer transform sur les captures bronze concernées, **vers staging** ;
  3. Diff staging vs main (quantifier ce qui va changer) ;
  4. Décision explicite (revue humaine si volumes anormaux) puis application à `main` —
     les changements passent par les mêmes chemins que le nominal (audit_trail alimenté,
     survivance respectée, corrections manuelles MIN préservées — fiche 04) ;
  5. Entrée CHANGELOG (un backfill est un événement métier : les chiffres des dashboards
     changent rétroactivement, le métier doit le savoir).
- Le pattern **Write-Audit-Publish** (fiche 03) s'applique intégralement : un backfill
  n'écrit jamais directement en gold.

### 3. Sauvegarde et reprise — du point de vue data

Le document à produire (une page) et à faire valider avec l'infra :

- **Inventaire par criticité** :

| Donnée | Reconstructible ? | Criticité sauvegarde |
|--------|-------------------|----------------------|
| `source` (bronze) | **Non** — c'est l'historique des sources ; les sources amont ne le rejoueront pas | **Maximale** — c'est LA donnée irremplaçable |
| Décisions humaines : fusions/corrections MIN, `merge_log`, `audit_trail`, crosswalk | **Non** — travail humain accumulé | **Maximale** |
| `staging`, `main`, `api`, `dataviz` | Oui, depuis bronze + code + décisions humaines | Modérée (la sauvegarde accélère la reprise, mais la perte n'est pas définitive) |
| Schémas/DDL | Oui — Flyway dans le repo | Aucune (le repo est la sauvegarde) |

  C'est l'un des bénéfices majeurs de l'architecture en couches : elle **réduit la surface
  de données irremplaçables** à bronze + décisions humaines. Sans elle, tout `main` est
  irremplaçable.

- **RPO/RTO explicites** : "on accepte de perdre au plus X heures de données (RPO), on
  repart en Y heures (RTO)". Même des valeurs modestes (RPO 24 h / RTO 1 jour) écrites
  valent mieux qu'un implicite jamais discuté — c'est un arbitrage produit, pas technique.
- **Test de restauration périodique** : une sauvegarde jamais restaurée est une hypothèse,
  pas une sauvegarde. Un exercice semestriel (restaurer dans un environnement jetable,
  vérifier les comptages vs `pipeline_metrics`) — et le rafraîchissement automatisé de dev
  (§1) peut *être* ce test, d'une pierre deux coups.
- **Scénarios à couvrir** : perte de la base (restore + rejouer les DAGs depuis la dernière
  sauvegarde), corruption logique (mauvais backfill : restore ciblé de tables depuis la
  sauvegarde ou re-calcul depuis bronze), perte de l'hébergeur (sauvegarde externalisée de
  bronze + décisions humaines — à minima un dump chiffré hors site).

## Par où commencer

1. La page DR : inventaire par criticité + RPO/RTO proposés + état réel des sauvegardes
   hébergeur (une demi-journée, dont une conversation avec l'infra).
2. Automatiser le rafraîchissement de dev (DAG mensuel dump → pseudo → restore) — qui sert
   aussi de test de restauration.
3. Règle d'équipe "changement de règle métier = run sur dev + diff joint à la MR".
4. Conventions de backfill dans les DAGs (paramètre date/capture) — à intégrer au chantier
   couche source (fiche 01) plutôt qu'après coup.

## Pièges connus

- **Le dev qui diverge** : un environnement dev jamais rafraîchi donne des validations
  fausses ; un dev rafraîchi sans pseudonymisation est une fuite RGPD. L'automatisation
  règle les deux.
- **Le backfill cowboy** : `UPDATE` manuel en prod pour "corriger vite" — invisible de
  l'audit_trail, écrasé au prochain run, indocumenté. La procédure de backfill existe pour
  que le chemin propre soit aussi le chemin facile.
- **Confondre sauvegarde et historisation** : les sauvegardes protègent d'un sinistre, pas
  d'une question métier ("les chiffres d'il y a 6 mois") — ça, c'est la fiche 09.
- **RPO/RTO décidés par défaut par l'infra** : c'est un choix produit (combien d'heures de
  saisies MIN peut-on perdre ?) — le PO doit signer.

## Aller plus loin

- **Branches de données / environnements éphémères** (Neon, Postgres branching ; lakeFS
  côté fichiers) : créer une "branche" copy-on-write de la base par MR pour prévisualiser
  l'impact — l'état de l'art émergent du "preview environment" data. Signal de bascule :
  si les runs de validation sur dev deviennent un goulot (plusieurs changements de règles
  en parallèle).
- **Blue/green data deployments** : construire la nouvelle version des tables à côté
  (`main_next`), basculer par renommage/vue une fois validée — utile pour les refontes
  majeures de `main` ; le pattern WAP en est la version légère.
- **Chaos engineering data** : injecter des pannes (source vide, colonnes permutées) pour
  tester les défenses (contrats, tests, quarantaine) — pertinent une fois les fiches 02/03
  en place, comme exercice annuel.
- **PITR (Point-In-Time Recovery)** PostgreSQL : restauration à la seconde près via WAL
  archiving — si l'hébergeur le propose, c'est le meilleur RPO possible pour un coût
  faible ; à vérifier dans la conversation infra du §1.

## Références

- Airflow — *Backfill*, `logical_date`, idempotence des tâches (cf. aussi *Functional Data
  Engineering*, Beauchemin — fiche 01)
- PostgreSQL — `pg_dump`/`pg_restore`, PITR & WAL archiving
- PostgreSQL Anonymizer — pseudonymisation des environnements (aussi en fiche 11)
- Pattern Write-Audit-Publish (fiche 03)
