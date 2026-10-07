# Documentation — index

Point d'entrée unique de la documentation du dépôt. Tout document versionné doit y figurer.

> Réorganisation en cours (SEPT #2058) : les documents sont rangés ; restent la fusion des doublons, l'extraction des ADR et la réécriture des documents dépassés, signalés par ⚠️. L'ancien dossier `approche-data/` est réparti entre `architecture/`, `chantiers/` et `archive/` : correspondance des anciens numéros de fiche dans [architecture/README.md](architecture/README.md#fiches-détaillées).

## Organisation

```
docs/
  README.md          cet index
  guides/            faire quelque chose : installer, déployer, restaurer, diagnostiquer
  reference/
    sources/         une source de données = un doc technique + un doc -metier
    regles/          règles métier transverses (cycle de vie, survivance, contacts…)
    api/             PostgREST, contrats de sortie
  architecture/      principes et cible (couches, qualité, sécurité…)
  adr/               décisions actées, une par fichier (voir adr/README.md)
  chantiers/
    <ticket>-<sujet>/  documents de travail d'un chantier : analyses, plans, audits, points d'étape
  archive/           chantiers clos et documents remplacés, gardés pour l'historique
```

À la racine du dépôt, seulement `README.md`, `CHANGELOG.md`, `CHANGELOG-metier.md`, `CLAUDE.md` et `CONTRIBUTING.md`. Les README d'outils (`tools/*/`, `scripts/`, `tests/`, `contracts/`) restent à côté de ce qu'ils décrivent.

## Cycle de vie d'un document

Trois sortes de documents, trois cycles :

| Sorte | Où | Cycle |
|---|---|---|
| **Référence** (guides, reference, architecture) : ce qui est vrai aujourd'hui | `guides/`, `reference/`, `architecture/` | **Vivant.** Un seul document par sujet ; une MR qui change le comportement le met à jour. On ne crée pas de second document à côté |
| **Décision** : pourquoi on a choisi X | `adr/` | **Figée.** On ne la réécrit pas, on la remplace par un nouvel ADR |
| **Travail** : analyse, plan, audit, diagnostic, point d'étape | `chantiers/<ticket>-<sujet>/` | **Temporaire.** À la clôture du chantier : décisions → ADR, référence mise à jour, dossier → `archive/` |

La clôture d'un chantier n'est complète que lorsque ces trois gestes sont faits.

## Conventions

- **Nommage** : `kebab-case.md`, en français. Date `AAAAMMJJ` en suffixe seulement pour les documents de travail datés. Version non technique d'un document : suffixe `-metier`.
- **En-tête** obligatoire sous le titre :

  ```markdown
  > **Statut** : vivant | brouillon | figé | obsolète · **Public** : tech | métier · **Mis à jour** : AAAA-MM-JJ · **Tickets** : #… · **Remplacé par** : … (si obsolète)
  ```

- **Pas de données personnelles**, versionnées ou non : pas de liste nominative, pas d'email ou de téléphone de personne (même dans un exemple), rôles plutôt que prénoms d'interlocuteurs extérieurs. Les coordonnées d'organisation ne sont pas des données personnelles.
- **Pas de renvoi vers une mémoire d'agent** ou un fichier local : un lien pointe vers un fichier versionné, un ticket ou une MR.
- **Pointeurs de code** : `fichier:ligne` quand c'est utile, en évitant les zones qui bougent souvent.
- **Audience** : l'équipe humaine (référents, contributeurs, PO via les versions `-metier`) et les agents IA, qui doivent pouvoir raisonner sans deviner. Expliquer le pourquoi, pas seulement décrire le code.

### Quand écrire

- MR non triviale sur un sujet documenté : mettre à jour le document de référence concerné, dans la même MR.
- Décision prise : un ADR.
- Investigation ou chantier qui produit une analyse : `chantiers/<ticket>-<sujet>/`.
- En plus, pour toute MR à impact : entrées dans `CHANGELOG.md` et `CHANGELOG-metier.md` (voir `CLAUDE.md`, section *Documentation des changements* ; rattrapage avec le skill `/changelog`).

### Wiki GitLab ou `docs/`

- **Wiki GitLab** : onboarding général, vue d'ensemble, FAQ.
- **`docs/`** : architecture, règles métier, décisions, runbooks. Versionné avec le code, lu en parallèle des sources.
- **DAT** : sur l'espace documentaire interne, jamais dans ce dépôt public.

## Suivi des évolutions

| Document | Pour quoi |
|---|---|
| [../CHANGELOG.md](../CHANGELOG.md) | Journal technique des changements (hash, détails, impact) |
| [../CHANGELOG-metier.md](../CHANGELOG-metier.md) | Même journal en langage non technique, pour le PO, les partenaires et l'équipe métier |

## Guides

| Document | Pour quoi |
|---|---|
| [guides/dev-setup.md](guides/dev-setup.md) | Installation locale : Docker Compose, Flyway, PostgreSQL/PostGIS, Metabase, dépannage |
| [guides/ci-cd-orchestrator.md](guides/ci-cd-orchestrator.md) | DAGs orchestrateur, restauration des sauvegardes, rapports d'évaluation, verdicts |
| [guides/notifications-mattermost.md](guides/notifications-mattermost.md) | Notifications Mattermost depuis Airflow |
| [../tests/README.md](../tests/README.md) · [../tests-unitaires/README.md](../tests-unitaires/README.md) | Tests d'intégration et rapports de validation · tests unitaires purs |
| [../scripts/README.md](../scripts/README.md) · [../tools/](../tools/) | Scripts et outils ponctuels (un README par outil) |

## Référence — sources de données

| Source / DAG | Technique | Métier |
|---|---|---|
| Coop / `coop-import` | [coop.md](reference/sources/coop.md) ⚠️ §Structures | [coop-metier.md](reference/sources/coop-metier.md) ⚠️ |
| Conseillers numériques / `schema-idPoste` | [conseillers-numeriques.md](reference/sources/conseillers-numeriques.md) ⚠️ | [conseillers-numeriques-metier.md](reference/sources/conseillers-numeriques-metier.md) |
| Cartographie nationale / `carto-dag-import` | [cartographie-nationale.md](reference/sources/cartographie-nationale.md) ⚠️ décrit encore `mednum-cli` | [cartographie-nationale-metier.md](reference/sources/cartographie-nationale-metier.md) |
| Aidants Connect / `aidants-connect-import` | [aidants-connect.md](reference/sources/aidants-connect.md) ⚠️ §Modèle | [aidants-connect-metier.md](reference/sources/aidants-connect-metier.md) |
| Enrichissement SIRENE + BAN (transverse) | [enrichissement-sirene-ban.md](reference/sources/enrichissement-sirene-ban.md) ⚠️ ignore les caches V137 | — |
| Contrats de données en entrée | [../contracts/README.md](../contracts/README.md) | — |

⚠️ Plusieurs de ces documents décrivent encore `main.structure`, supprimée en V148 : la cible est `main.structure_administrative`.

## Référence — règles métier

| Document | Pour quoi |
|---|---|
| [cycle-de-vie-lieux-personnes.md](reference/regles/cycle-de-vie-lieux-personnes.md) | Apparition, mise à jour et disparition des lieux et des personnes, sur toutes les interfaces |
| [cycle-de-vie-lieux-personnes-support.md](reference/regles/cycle-de-vie-lieux-personnes-support.md) | Même sujet pour le support : pourquoi un lieu ou un médiateur s'affiche ou non |
| [cycle-de-vie-lieux-personnes-preuves.md](reference/regles/cycle-de-vie-lieux-personnes-preuves.md) | Matrice assertion → preuve (tests, requêtes) ; manifeste [cycle-de-vie.gardes.yml](reference/regles/cycle-de-vie.gardes.yml) lu par le job CI `docs-guard` |
| [visibilite-api-carto-20260914.md](reference/regles/visibilite-api-carto-20260914.md) | Note courte sur la visibilité des médiateurs (à fusionner dans la version support) |
| [regles-survivance.md](reference/regles/regles-survivance.md) | Quand deux sources se contredisent, laquelle gagne (état de fait) |
| [id-poste-regles.md](reference/regles/id-poste-regles.md) | Déduplication des structures idPoste par `structure_tp_id` |
| [subventions-conseiller-numerique.md](reference/regles/subventions-conseiller-numerique.md) | Modèle des subventions des postes CN (enveloppes, bonifications) |
| [contact-personne.md](reference/regles/contact-personne.md) | Champ JSONB `contact` des personnes, par source |
| [../database/data_dict.md](../database/data_dict.md) ⚠️ | Dictionnaire de données généré, à régénérer (liste des tables supprimées) |

## Référence — API

| Document | Pour quoi |
|---|---|
| [postgrest.md](reference/api/postgrest.md) | API REST : authentification JWT, rôles, schémas exposés, ajout d'un endpoint |

## Architecture

| Document | Pour quoi |
|---|---|
| [architecture/README.md](architecture/README.md) ⚠️ | Diagnostic, cible et principes de la plateforme data ; index des fiches et correspondance avec les anciens numéros. Les sections « État actuel » des fiches datent d'avant V127 |
| [flux-globaux.md](architecture/flux-globaux.md) | Producteurs, consommateurs et écritures autour du dataspace |
| [architecture-medallion.md](architecture/architecture-medallion.md) · [pattern-flux-reference.md](architecture/pattern-flux-reference.md) · [architecture-code-fcis.md](architecture/architecture-code-fcis.md) | Couches bronze / silver / gold, pattern d'ingestion « bronze d'abord », organisation du code (FCIS) |
| [data-contracts.md](architecture/data-contracts.md) · [qualite-donnees.md](architecture/qualite-donnees.md) · [observabilite-lineage.md](architecture/observabilite-lineage.md) | Contrats d'entrée, qualité et quarantaine, observabilité |
| [mdm-reconciliation.md](architecture/mdm-reconciliation.md) · [historisation-scd.md](architecture/historisation-scd.md) · [modelisation-gold.md](architecture/modelisation-gold.md) | Réconciliation et survivance, historisation, modélisation du gold |
| [securite-acces.md](architecture/securite-acces.md) · [api-data-produit.md](architecture/api-data-produit.md) · [environnements-backfills-dr.md](architecture/environnements-backfills-dr.md) | Droits et accès, API comme produit, environnements et reprise |
| [gouvernance-catalogue.md](architecture/gouvernance-catalogue.md) · [transformations-elt-dbt.md](architecture/transformations-elt-dbt.md) · [panorama-pratiques-avancees.md](architecture/panorama-pratiques-avancees.md) | Gouvernance et catalogue, passage à l'ELT (dbt), pratiques évaluées et non retenues |

## Décisions

[adr/](adr/README.md) — index des ADR.

## Chantiers en cours

| Chantier | Documents |
|---|---|
| #2013 refonte structure | [refonte-structure-plan.md](chantiers/2013-refonte-structure/refonte-structure-plan.md), [refonte-structure-metriques.md](chantiers/2013-refonte-structure/refonte-structure-metriques.md), [refonte-structure-phase-3-test.md](chantiers/2013-refonte-structure/refonte-structure-phase-3-test.md), [fusion-structures-synthese-po.md](chantiers/2013-refonte-structure/fusion-structures-synthese-po.md) |
| #1534 adresse canonique | [audit-adresse-canonique-sirene.md](chantiers/1534-adresse-canonique/audit-adresse-canonique-sirene.md), [etat-des-lieux-adresse-canonique.md](chantiers/1534-adresse-canonique/etat-des-lieux-adresse-canonique.md), [plan-correction-adresses-ac-suite.md](chantiers/1534-adresse-canonique/plan-correction-adresses-ac-suite.md), [fix-ingestion-ac-geocodage-cp.md](chantiers/1534-adresse-canonique/fix-ingestion-ac-geocodage-cp.md) |
| #1724 lieux d'inclusion | [analyse-bascule-vue-union-v153.md](chantiers/1724-lieux-inclusion/analyse-bascule-vue-union-v153.md) |
| Plateforme data | [feuille-de-route.md](chantiers/plateforme-data/feuille-de-route.md) ⚠️ statuts à mettre à jour |
| Survivance du gold | [cartographie-ecritures-gold.md](chantiers/survivance-gold/cartographie-ecritures-gold.md), [decisions-survivance.md](chantiers/survivance-gold/decisions-survivance.md) (arbitrage métier en attente) |
| Crosswalk d'identifiants | [conception-crosswalk.md](chantiers/crosswalk/conception-crosswalk.md) |
| Corrections MIN comme source | [conception-overrides-min.md](chantiers/overrides-min/conception-overrides-min.md) |
| Rétention bronze | [retention-bronze.md](chantiers/retention-bronze/retention-bronze.md) |
| Questions au métier | [questions-metier-en-cours.md](chantiers/questions-metier/questions-metier-en-cours.md) ⚠️ une partie des questions est caduque |
| #2058 organisation documentaire | [inventaire-20261005.md](chantiers/2058-organisation-documentaire/inventaire-20261005.md) |

## Archive

| Document | Raison |
|---|---|
| [api-carto-structures-regles.md](archive/api-carto-structures-regles.md) | Figé à V061-V063 ; remplacé par `cycle-de-vie-lieux-personnes.md` |
| [enrichissement-adresse.md](archive/enrichissement-adresse.md) | Phase 0 jamais terminée ; code cité supprimé |
| [analyse-updated-at-lieu-inclusion.md](archive/analyse-updated-at-lieu-inclusion.md) | Résolu par V115 / V116 |
| [spec-couche-source.md](archive/spec-couche-source.md) | Couche bronze livrée (V099) |
| [plan-remise-au-propre.md](archive/plan-remise-au-propre.md) | Plan de remise au propre terminé (ex-fiche 17) |

## Documentation dans les autres dépôts

| Dépôt | Où | Sujets |
|---|---|---|
| MIN (`anct-cnum/suite-gestionnaire-numerique`) | `docs/README.md`, `docs/adr/` | Écrans (postes CN, membres de gouvernance), statistiques coop, intégration MIN ↔ dataspace (migrations Prisma miroir). Les règles des données partagées sont documentées ici, dans le dataspace |
| Nao (`incubateur-territoires/nao-context-inclusion-numerique`) | `RULES.md`, `agent/semantics/` | Contexte de l'agent LLM sur le schéma `llm` |
| Consommateurs du schéma | `CLAUDE.md`, section *Consommateurs du schéma* | Ce que chaque dépôt lit ou écrit, à vérifier avant une migration destructive |
