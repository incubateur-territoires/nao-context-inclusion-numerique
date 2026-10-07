# 08 — Feuille de route

← [Retour au document central](../../architecture/README.md)

## Principes de séquencement

- **Fondations d'abord** : tout s'appuie sur le brut immuable et les tests — les faire en premier.
- **Valeur visible tôt** : chaque étape produit un bénéfice observable (moins d'incidents,
  info visible par le métier), pas seulement de la plomberie.
- **Pas de big bang** : le pipeline actuel continue de tourner ; chaque brique migre flux
  par flux avec preuve d'iso-résultat.
- **Documenter avant d'outiller** : écrire les règles (survivance, contrats) coûte des
  jours et débloque tout ; les outils viennent après.

## Étape 1 — Fondation : brut immuable + contrats

*Fiches [01](../../architecture/architecture-medallion.md) et [02](../../architecture/data-contracts.md)*

| Action | Effort | Note |
|--------|--------|------|
| Implémenter la couche `source` append-only | Moyen | Spec déjà écrite — c'est le chantier en cours, le prioriser |
| Table `source.capture_run` (runs horodatés, volumétrie) | Faible | Socle de l'observabilité |
| Contrats YAML des flux existants (rétro-ingénierie de `ingest/`) | Moyen | Révélera des hypothèses implicites — c'est le but |
| Validation de contrat à l'extract, mode warn | Faible | pandera ou jsonschema, tâche Airflow par flux |
| Vérifier le déterminisme des UUID | Faible | Prérequis absolu du crosswalk (étape 3) |

**Critère de sortie** : plus aucune donnée source n'est perdue ou écrasée ; tout drift de
schéma déclenche une alerte.

## Étape 2 — Filet de sécurité : qualité bloquante

*Fiche [03](../../architecture/qualite-donnees.md)*

| Action | Effort | Note |
|--------|--------|------|
| Convertir les 3 rapports manuels en tests SQL | Moyen | Les bonnes questions existent déjà |
| Tâches `tests_staging` / `tests_main` dans les DAGs, warn 2 semaines puis bloquant | Faible | `SQLCheckOperator` natif |
| Table `staging.rejets` (quarantaine) + routage des filtres d'exclusion | Moyen | Fin des drops silencieux |
| Passer les contrats (étape 1) en mode bloquant | Faible | Flux par flux |

**Critère de sortie** : des données violant un invariant ne peuvent plus atteindre `main` ;
toute ligne écartée est visible avec son motif.

## Étape 3 — Lisibilité métier : règles et définitions

*Fiches [04](../../architecture/mdm-reconciliation.md) et [07](../../architecture/gouvernance-catalogue.md)*

| Action | Effort | Note |
|--------|--------|------|
| Tableau des règles de survivance (rétro-ingénierie), validé par le métier | Moyen | **Le document le plus rentable de toute la feuille de route.** Rétro-ingénierie des règles *constatées* faite ([fiche 18](../survivance-gold/cartographie-ecritures-gold.md), 2026-07-30) ; tableau de décision arbitrable rédigé ([fiche 20](../survivance-gold/decisions-survivance.md), 2026-07-31) ; **reste l'arbitrage métier ligne à ligne** |
| Crosswalk d'identifiants pérenne (schéma dédié `crosswalk`, tables `crosswalk.{structure,personne,lieu}`, décision C8) | Moyen | Spec de conception rédigée ([fiche 21](../crosswalk/conception-crosswalk.md), 2026-07-31) ; implémentation après validation des 7 points de décision |
| Seuils de matching en configuration (hors code) | Faible | |
| `COMMENT ON` sur toutes les colonnes `api.*`, puis `main.*` | Faible | Visible immédiatement via OpenAPI/Metabase |
| Tableau d'ownership + registre des données personnelles | Faible | Avec PO et référent |

**Critère de sortie** : un PO ou un partenaire peut comprendre chaque champ exposé et
chaque règle de fusion sans lire de Python.

## Étape 4 — Industrialisation : ELT SQL + CI data

*Fiche [05](../../architecture/transformations-elt-dbt.md)*

| Action | Effort | Note |
|--------|--------|------|
| ~~Décision dbt Core vs SQL pur~~ | — | **Décidé 2026-07-31 : dbt Core.** Mise en œuvre conditionnée aux prérequis de la [fiche 05](../../architecture/transformations-elt-dbt.md#prérequis-avant-le-premier-modèle) : tableau de survivance validé (étape 3), crosswalk (étape 3), doctrine des overrides MIN |
| Pilote : flux simple migré source → staging → mart, iso-résultat prouvé | Moyen | aidants-connect est un bon candidat |
| Migration des autres ingest, flux par flux | Élevé | Supprimer le pandas correspondant à chaque bascule |
| Migration de la réconciliation en SQL (sur la base des règles documentées à l'étape 3) | Élevé | En dernier — le plus complexe |
| CI data : échantillon versionné + `dbt build`/tests sur PostGIS éphémère + test d'idempotence | Moyen | Réutilise le pattern CI de `test_migration` |

**Critère de sortie** : plus aucun état intermédiaire en CSV temp ; une MR montre son
impact données en CI ; le pipeline est prouvé idempotent.

### Problème RÉSOLU — les états post-enrichissement restaient en CSV (clos 2026-07-30)

La bascule silver (AC, coop, FRR, QPV, idposte) excluait les états POST-enrichissement
par APIs externes (`structure_enriched.csv` idposte, `new_structures_enriched.csv`
AC/coop) : non re-dérivables depuis le bronze seul, donc pas du silver au sens strict.

Résolu par le chantier « caches d'enrichissement » (fiche
[05](../../architecture/transformations-elt-dbt.md), 2 lots, 2026-07-30) : V137 crée
`staging.sirene__cache` et `staging.geocodage__cache`, référentiels accumulés adressés
par clé d'entrée (SIRET normalisé, triplet adresse/citycode/postcode soumis à l'API),
TTL 4 mois. L'état enrichi = silver du flux ⋈ caches, recalculé par les cores purs
`consolider_structures*` (`etl/core/{idposte,ac,coop}.py`) — plus aucun CSV enrichi ni
XCom d'état dans les 3 flux enrichisseurs. Écart métier tracé au passage : les
géocodages invalides (score < 0.5) ne sont plus consommés.

## Étape 5 — Pilotage : observabilité et stewardship

*Fiches [06](../../architecture/observabilite-lineage.md) et [04](../../architecture/mdm-reconciliation.md)*

| Action | Effort | Note |
|--------|--------|------|
| `admin.pipeline_metrics` + écriture par les tâches | Faible | Peut démarrer dès l'étape 2 |
| Check quotidien fraîcheur vs SLA → Mattermost | Faible | Attrape les échecs silencieux |
| Dashboard Metabase "santé du pipeline" | Faible | Metabase déjà en place |
| Fraîcheur exposée dans MIN et `api.metadata_flux` | Faible | Côté MIN : dépend de l'équipe MIN |
| `inlets`/`outlets` OpenLineage sur les DAGs ; dbt docs publiées | Faible | |
| **File de revue humaine des matchs ambigus dans MIN** + priorité aux corrections manuelles | Élevé | Le chantier le plus différenciant ; dépend de l'équipe MIN. Conception des overrides rédigée ([fiche 22](../overrides-min/conception-overrides-min.md), 2026-07-31) |

**Critère de sortie** : une anomalie de données est détectée par l'équipe avant les
utilisateurs ; le métier arbitre les fusions dans MIN.

## Dépendances entre étapes

```
Étape 1 (source + contrats)
   ├──► Étape 2 (qualité)  ──► Étape 4 (ELT/CI data)
   └──► Étape 3 (règles, crosswalk) ──► Étape 4 (réconciliation SQL)
                                    └─► Étape 5 (revue humaine MIN)
Étape 5 (métriques/fraîcheur) : démarrable en parallèle dès l'étape 2
```

Les étapes 1-2 sont l'investissement défensif (plus d'incidents silencieux). L'étape 3 est
le pivot culturel (les règles sortent du code). Les étapes 4-5 transforment la plateforme.

## Chantiers transverses (hors séquencement)

Démarrables à tout moment, indépendamment des étapes 1-5 — surtout documentaires :

| Action | Effort | Fiche |
|--------|--------|-------|
| Matrice d'accès rôles × schémas + `ALTER DEFAULT PRIVILEGES` + test de GRANT en CI | Faible/Moyen | [11](../../architecture/securite-acces.md) |
| Rétro-documentation du modèle `main` (diagramme + granularité) + conventions | Faible | [10](../../architecture/modelisation-gold.md) |
| Page DR : inventaire par criticité, RPO/RTO, test de restauration | Faible | [13](../../architecture/environnements-backfills-dr.md) |
| Registre des consommateurs API + doctrine versionnement/dépréciation + garde-fou CI sur les vues `api` | Moyen | [12](../../architecture/api-data-produit.md) |
| Rafraîchissement automatisé de l'environnement dev (dump → pseudo → restore) | Moyen | [13](../../architecture/environnements-backfills-dr.md) |
| Modèle dimensionnel `dataviz` (dim_territoire, dim_temps) — après l'étape 3 idéalement | Moyen | [10](../../architecture/modelisation-gold.md) |

## Anti-objectifs

Ce qu'on ne fait **pas**, à cette échelle — chaque pratique écartée est documentée en
détail dans la [fiche 14](../../architecture/panorama-pratiques-avancees.md), avec le concept, la raison
et le **signal de bascule** qui rouvrirait la discussion :

- Pas de data lake / lakehouse / object storage : PostgreSQL suffit largement.
- Pas de plateforme de catalogue (DataHub, OpenMetadata) : `COMMENT ON` + dbt docs.
- Pas de plateforme d'observabilité dédiée : une table de métriques + Metabase.
- Pas de streaming/temps réel : les besoins sont batch quotidiens.
- Pas de data mesh, semantic layer outillé, MLOps, reverse ETL outillé, fédération (voir fiche 14).
- Pas de refonte big bang du pipeline : étranglement progressif, iso-résultat prouvé.
