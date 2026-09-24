# Approche data — Document de référence

> Diagnostic de l'existant et cible pour passer d'un pipeline "dev qui manipule des données"
> à une véritable plateforme data. Chaque axe renvoie vers une fiche détaillée qui explique
> le concept, l'état de l'art et la mise en place concrète sur ce projet.

## Contexte

Le projet centralise des données issues de plusieurs sources (carto, coop, aidants-connect,
conseillers numériques…), les réconcilie et les expose via :

- **MIN** : interface de gestion / back-office (schéma `min`)
- **PostgREST** : API publique (schéma `api`)
- **Metabase** : dashboards (schéma `dataviz`)

La chaîne actuelle : Airflow orchestre des scripts pandas (`etl/extract` → `etl/transform` →
`etl/load`), les données transitent par des CSV temporaires, et atterrissent dans le schéma
`main` de PostgreSQL. Les migrations sont gérées par Flyway.

## Diagnostic — pourquoi ce n'est pas (encore) une approche data

| # | Constat | Conséquence | Fiche |
|---|---------|-------------|-------|
| 1 | **Pas de couche brute immuable** : le schéma `import` est écrasé à chaque run | Impossible de rejouer un traitement passé, d'auditer ce qu'une source a réellement envoyé, ou de corriger un bug rétroactivement | [01 — Architecture en couches](01-architecture-medallion.md) |
| 2 | **Transformations opaques** : pandas → CSV dans des répertoires temporaires → load | États intermédiaires ni inspectables, ni testables, ni requêtables ; debugging à l'aveugle | [01](01-architecture-medallion.md), [05 — ELT & dbt](05-transformations-elt-dbt.md) |
| 3 | **Aucun contrat avec les sources** : le schéma attendu n'est décrit nulle part | Un changement de champ côté source = crash en prod, ou pire, données silencieusement fausses | [02 — Data contracts](02-data-contracts.md) |
| 4 | **Qualité de données manuelle** : `rapport_comptage.py` / `rapport_validation.py` lancés à la main avant/après | Rien ne bloque un chargement de données invalides ; la qualité dépend de la vigilance humaine | [03 — Qualité de données](03-qualite-donnees.md) |
| 5 | **Réconciliation = code, pas règles** : dédup rapidfuzz enfouie dans du Python, règles de survivance implicites | Le métier ne peut ni comprendre ni valider "quelle source gagne sur quel champ" ; fusions difficiles à auditer | [04 — MDM & réconciliation](04-mdm-reconciliation.md) |
| 6 | **Pas d'observabilité data** : DAG vert ≠ données bonnes | Fraîcheur, volumétrie, dérive : rien n'est suivi, les anomalies sont découvertes par les utilisateurs | [06 — Observabilité & lineage](06-observabilite-lineage.md) |
| 7 | **Pas de gouvernance** : pas de dictionnaire de données, pas d'ownership explicite | Les consommateurs (MIN, partenaires API) interprètent les champs à leur manière ; connaissance dans les têtes | [07 — Gouvernance & catalogue](07-gouvernance-catalogue.md) |
| 8 | **CI orientée code, pas data** : la CI vérifie que les DAGs se chargent, pas que les transformations sont justes | Une MR qui change une règle métier ne montre pas son impact sur les données avant merge | [03](03-qualite-donnees.md), [05](05-transformations-elt-dbt.md) |
| 9 | **Modèle de données jamais formalisé** : pas de diagramme maintenu, granularité des tables implicite, `dataviz` construit dashboard par dashboard | Évolutions du schéma découvertes en marchant ; chiffres potentiellement divergents entre dashboards | [10 — Modélisation](10-modelisation-gold.md) |
| 10 | **Accès gérés au cas par cas** : GRANT réécrits dans chaque migration, pas de matrice de droits, incidents de grants incomplets déjà survenus | Impossible de savoir qui peut faire quoi sans grepper les migrations ; sécurité par vigilance humaine | [11 — Sécurité & accès](11-securite-acces.md) |
| 11 | **Pas de doctrine pour nos propres consommateurs** : versionnement des vues `api` empirique, pas de politique de dépréciation ni de registre des usages | On peut faire subir à nos partenaires exactement ce qu'on reproche à nos sources (constat 3, en miroir) | [12 — API data produit](12-api-data-produit.md) |
| 12 | **Ni backfill, ni doctrine DR** : impossible de rejouer le passé, RPO/RTO jamais définis, restauration jamais testée | Un bug de transformation laisse l'historique faux sans recours ; ce qu'on perdrait en cas de sinistre est inconnu | [13 — Environnements & DR](13-environnements-backfills-dr.md) |

## Ce qui existe déjà et va dans le bon sens

- Séparation en schémas PostgreSQL (`import` / `admin` / `reference` / `main` / `api` / `dataviz` / `auth` / `min`) — embryon d'architecture en couches.
- Migrations versionnées (Flyway) avec CI de test sur instance fraîche.
- `main.audit_trail` (V124) et `merge_log` — début de traçabilité des modifications et fusions.
- Spec de la **couche `source` append-only** (en cours) — c'est exactement la fondation bronze manquante.
- Tables de similarités (`similarities-personne`, `structure-similarities`) — matière première d'un vrai MDM.
- Rapports de validation existants — à transformer en tests bloquants plutôt qu'à jeter.

## Cible

```
Sources ──► SOURCE (bronze)     ──► STAGING (silver)      ──► MAIN (gold)        ──► Consommateurs
            brut, append-only,      typé, nettoyé,             réconcilié, MDM,       min / api /
            immuable, historisé     dédup par source,          règles de survivance   dataviz
                                    100% reconstructible       documentées
     ▲               ▲                      ▲                        ▲
     │               │                      │                        │
  contrats de     capture               tests qualité            audit_trail,
  schéma (02)     horodatée (01)        bloquants (03)           crosswalk (04)

  Transverse : transformations SQL déclaratives testées (05), observabilité
  fraîcheur/volumétrie/lineage (06), dictionnaire de données & ownership (07)
```

Principes non négociables :

1. **Immutabilité du brut** — on ne perd jamais ce qu'une source a envoyé.
2. **Idempotence** — rejouer un pipeline N fois produit le même résultat.
3. **Reproductibilité** — tout état aval est reconstructible depuis le brut.
4. **Qualité bloquante** — des données invalides ne passent pas en `main` sans décision explicite.
5. **Traçabilité** — chaque valeur en `main` a une provenance et une règle identifiables.
6. **Lisibilité métier** — les règles (survivance, dédup, rejets) sont documentées hors du code.

## Fiches détaillées

| Fiche | Sujet | Répond à |
|-------|-------|----------|
| [01-architecture-medallion.md](01-architecture-medallion.md) | Architecture en couches (bronze / silver / gold), immutabilité, idempotence | Constats 1, 2 |
| [02-data-contracts.md](02-data-contracts.md) | Contrats de schéma avec les sources, détection de drift | Constat 3 |
| [03-qualite-donnees.md](03-qualite-donnees.md) | Tests de qualité déclaratifs et bloquants, quarantaine des rejets, CI data | Constats 4, 8 |
| [04-mdm-reconciliation.md](04-mdm-reconciliation.md) | Master Data Management : crosswalk d'identifiants, règles de survivance, revue humaine | Constat 5 |
| [05-transformations-elt-dbt.md](05-transformations-elt-dbt.md) | Passer d'ETL pandas/CSV à de l'ELT SQL déclaratif (dbt), testable et documenté | Constats 2, 8 |
| [06-observabilite-lineage.md](06-observabilite-lineage.md) | Fraîcheur, volumétrie, alerting, lineage (OpenLineage natif Airflow 3) | Constat 6 |
| [07-gouvernance-catalogue.md](07-gouvernance-catalogue.md) | Dictionnaire de données, catalogue, ownership, RGPD / données personnelles | Constat 7 |
| [08-feuille-de-route.md](08-feuille-de-route.md) | Séquencement pragmatique : quoi faire, dans quel ordre, avec quel effort | — |
| [09-historisation-scd.md](09-historisation-scd.md) | Slowly Changing Dimensions : types, pourquoi pas de SCD2 sur `main`, snapshots et dbt snapshots | Constat 1 (volet historisation) |
| [10-modelisation-gold.md](10-modelisation-gold.md) | Modélisation : 3NF pour `main`, dimensionnel (étoile) pour `dataviz`, granularité, conventions, Data Vault | Constat 9 |
| [11-securite-acces.md](11-securite-acces.md) | Moindre privilège : matrice rôles × schémas, GRANT industrialisés et testés en CI, RLS, secrets, masquage | Constat 10 |
| [12-api-data-produit.md](12-api-data-produit.md) | Data as a product : contrats de sortie, versionnement/dépréciation des vues `api`, registre des consommateurs, open data | Constat 11 |
| [13-environnements-backfills-dr.md](13-environnements-backfills-dr.md) | DataOps : doctrine d'environnements, backfills propres, sauvegarde/reprise (RPO/RTO, criticité par couche) | Constat 12 |
| [14-panorama-pratiques-avancees.md](14-panorama-pratiques-avancees.md) | Le reste de l'état de l'art (streaming/CDC, lakehouse, semantic layer, data mesh, MLOps, reverse ETL…) : évalué, non retenu, avec **signaux de bascule** explicites | — |
| [15-pattern-flux-reference.md](15-pattern-flux-reference.md) | Pattern d'ingestion de référence ("bronze d'abord") : capture brute in-operator, base comme interface (run_id + source_key), load depuis `source.*` — état de conformité par flux et chemin de migration | Constats 1, 2 (volet harmonisation) |
| [16-architecture-code-fcis.md](16-architecture-code-fcis.md) | Architecture de code : Functional Core, Imperative Shell — logique métier en fonctions pures (`etl/core/`), infrastructure en coquille ; hexagonal formel évalué et écarté ; adoption via la migration bronze | Constats 2, 8 (volet code) |
| [17-plan-remise-au-propre.md](17-plan-remise-au-propre.md) | Plan opérationnel dirigé par les tests, en baby steps : harnais CI, boucle de migration type (capture → core TDD → bascule → nettoyage), ordre des flux, hygiène opportuniste — avec suivi d'avancement | Constat 8 (exécution des fiches 15, 16) |
| [18-cartographie-ecritures-gold.md](18-cartographie-ecritures-gold.md) | Rétro-ingénierie factuelle des écritures vers `main.*` : écrivains, clés, règles de survivance CONSTATÉES table par table, questions ouvertes pour l'arbitrage métier | Constat 5 (volet constat, socle de l'étape 3) |
| [19-retention-bronze.md](19-retention-bronze.md) | Rétention de la couche bronze `source.*` : volumétrie réelle et projections, classes de flux (stock complet / delta / snapshot / pull), politique cible, déclencheurs et mécanique de purge | Constat 1 (volet coût du append-only) |
| [20-decisions-survivance.md](20-decisions-survivance.md) | Tableau de décision métier des règles de survivance : condensé arbitrable de la fiche 18 (règle constatée → proposition → décision), prérequis n°1 de la bascule dbt | Constat 5 (volet arbitrage, étape 3) |
| [21-conception-crosswalk.md](21-conception-crosswalk.md) | Conception du crosswalk d'identifiants (spec avant code) : périmètre, schéma, namespaces, attribution des UUID, cohabitation avec les ID séquence, maintenance runtime — prérequis n°2 de la bascule dbt | Constat 5 (volet identifiants, étape 3) |
| [22-conception-overrides-min.md](22-conception-overrides-min.md) | Conception : les corrections humaines MIN comme source (overrides champ par champ dérivés de `source.min__evenements`, priorité de survivance maximale, cycle de vie, dépendances côté app MIN) — prérequis n°3 de la bascule dbt | Constat 5 (volet stewardship, étape 3) |

## Résumé de la feuille de route

Détail et critères de sortie dans [08-feuille-de-route.md](08-feuille-de-route.md).

1. **Fondation** — couche `source` append-only + contrats de schéma à l'extract. La couche existe en base et les [contrats sont rédigés](../contracts/README.md) ; reste l'harmonisation des flux sur le [pattern de référence](15-pattern-flux-reference.md) (un seul flux conforme à ce jour), chaque migration appliquant l'[architecture de code FCIS](16-architecture-code-fcis.md) (transformation réécrite en fonction pure testée).
2. **Filet de sécurité** — tests qualité bloquants dans les DAGs + table de quarantaine des rejets.
3. **Lisibilité métier** — documenter les règles de survivance et de dédup ; dictionnaire de données de `main` et `api`. Les règles *constatées* sont documentées ([fiche 18](18-cartographie-ecritures-gold.md)) ; reste le tableau de décision et sa validation métier.
4. **Industrialisation** — migrer les transformations vers du SQL en base : **dbt Core retenu (décision 2026-07-31)**, mise en œuvre conditionnée aux prérequis de la [fiche 05](05-transformations-elt-dbt.md) (survivance validée, crosswalk, overrides MIN) ; CI data sur échantillon.
5. **Pilotage** — fraîcheur et volumétrie monitorées avec alerting, lineage exposé.

Chantiers transverses, démarrables indépendamment (quick wins documentaires) : matrice
d'accès et tests de GRANT en CI ([11](11-securite-acces.md)), rétro-documentation du
modèle `main` ([10](10-modelisation-gold.md)), page DR avec RPO/RTO ([13](13-environnements-backfills-dr.md)),
registre des consommateurs API et doctrine de dépréciation ([12](12-api-data-produit.md)).

Enfin, la [fiche 14](14-panorama-pratiques-avancees.md) documente tout ce qui a été
**évalué et volontairement écarté** — avec, pour chaque pratique, le signal observable qui
devrait rouvrir la discussion. Toute proposition future du type "et si on faisait X ?"
trouve sa réponse argumentée là.
