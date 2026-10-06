# Documentation — index

Point d'entrée unique de la documentation du dépôt. Tout document versionné doit y figurer.

> Réorganisation en cours (SEPT #2058) : les documents sont listés ici selon leur **rubrique cible**. Ceux qui ne sont pas encore déplacés gardent leur chemin actuel. ⚠️ signale un document connu comme dépassé, en attente de réécriture.

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
| [DEV_SETUP.md](DEV_SETUP.md) | Installation locale : Docker Compose, Flyway, PostgreSQL/PostGIS, Metabase, dépannage |
| [ci-cd-orchestrator.md](ci-cd-orchestrator.md) | DAGs orchestrateur, restauration des sauvegardes, rapports d'évaluation, verdicts |
| [../Apache_Airflow_Mattermost_Notifications.md](../Apache_Airflow_Mattermost_Notifications.md) | Notifications Mattermost depuis Airflow |
| [../tests/README.md](../tests/README.md) · [../tests-unitaires/README.md](../tests-unitaires/README.md) | Tests d'intégration et rapports de validation · tests unitaires purs |
| [../scripts/README.md](../scripts/README.md) · [../tools/](../tools/) | Scripts et outils ponctuels (un README par outil) |

## Référence — sources de données

| Source / DAG | Technique | Métier |
|---|---|---|
| Coop / `coop-import` | [coop.md](coop.md) ⚠️ §Structures | [coop-metier.md](coop-metier.md) ⚠️ |
| Conseillers numériques / `schema-idPoste` | [conseillers-numeriques.md](conseillers-numeriques.md) ⚠️ | [conseillers-numeriques-metier.md](conseillers-numeriques-metier.md) |
| Cartographie nationale / `carto-dag-import` | [cartographie-nationale.md](cartographie-nationale.md) ⚠️ décrit encore `mednum-cli` | [cartographie-nationale-metier.md](cartographie-nationale-metier.md) |
| Aidants Connect / `aidants-connect-import` | [aidants-connect.md](aidants-connect.md) ⚠️ §Modèle | [aidants-connect-metier.md](aidants-connect-metier.md) |
| Enrichissement SIRENE + BAN (transverse) | [enrichissement-sirene-ban.md](enrichissement-sirene-ban.md) ⚠️ ignore les caches V137 | — |
| Contrats de données en entrée | [../contracts/README.md](../contracts/README.md) | — |

⚠️ Plusieurs de ces documents décrivent encore `main.structure`, supprimée en V148 : la cible est `main.structure_administrative`.

## Référence — règles métier

| Document | Pour quoi |
|---|---|
| [cycle-de-vie-lieux-personnes.md](cycle-de-vie-lieux-personnes.md) | Apparition, mise à jour et disparition des lieux et des personnes, sur toutes les interfaces |
| [cycle-de-vie-lieux-personnes-support.md](cycle-de-vie-lieux-personnes-support.md) | Même sujet pour le support : pourquoi un lieu ou un médiateur s'affiche ou non |
| [cycle-de-vie-lieux-personnes-preuves.md](cycle-de-vie-lieux-personnes-preuves.md) | Matrice assertion → preuve (tests, requêtes) |
| [regles-survivance.md](regles-survivance.md) | Quand deux sources se contredisent, laquelle gagne (état de fait) |
| [id-poste-regles.md](id-poste-regles.md) | Déduplication des structures idPoste par `structure_tp_id` |
| [subventions-conseiller-numerique.md](subventions-conseiller-numerique.md) | Modèle des subventions des postes CN (enveloppes, bonifications) |
| [CONTACT_MERGE.md](CONTACT_MERGE.md) | Champ JSONB `contact` des personnes, par source |
| [../database/data_dict.md](../database/data_dict.md) ⚠️ | Dictionnaire de données généré, à régénérer (liste des tables supprimées) |

## Référence — API

| Document | Pour quoi |
|---|---|
| [POSTGREST.md](POSTGREST.md) | API REST : authentification JWT, rôles, schémas exposés, ajout d'un endpoint |

## Architecture

| Document | Pour quoi |
|---|---|
| [flux-globaux.md](flux-globaux.md) | Producteurs, consommateurs et écritures autour du dataspace |
| [../approche-data/README.md](../approche-data/README.md) | Architecture cible (couches bronze / silver / gold, qualité, MDM, sécurité…) en 22 fiches. ⚠️ Les sections « État actuel » datent d'avant V127 |

## Décisions

[adr/](adr/README.md) — index des ADR.

## Chantiers en cours

| Chantier | Documents |
|---|---|
| #2013 refonte structure | [refonte-structure-plan.md](refonte-structure-plan.md), [refonte-structure-metriques.md](refonte-structure-metriques.md), [refonte-structure-phase-3-test.md](refonte-structure-phase-3-test.md), [fusion-structures-synthese-po.md](fusion-structures-synthese-po.md) |
| #1534 adresse canonique | [audit-adresse-canonique-sirene.md](audit-adresse-canonique-sirene.md), [etat-des-lieux-adresse-canonique.md](etat-des-lieux-adresse-canonique.md), [plan-correction-adresses-ac-suite.md](plan-correction-adresses-ac-suite.md), [fix-ingestion-ac-geocodage-cp.md](fix-ingestion-ac-geocodage-cp.md) |
| #1724 lieux d'inclusion | [../analyse_bascule_vue_union_v153.md](../analyse_bascule_vue_union_v153.md) |
| Questions au métier | [questions-metier-en-cours.md](questions-metier-en-cours.md) ⚠️ une partie des questions est caduque |
| #2058 organisation documentaire | `chantiers/organisation-documentaire/` (inventaire) |

## À archiver (étape 2 de #2058)

| Document | Raison |
|---|---|
| [api-carto-structures-regles.md](api-carto-structures-regles.md) | Figé à V061-V063 ; remplacé par `cycle-de-vie-lieux-personnes.md` |
| [ENRICHISSEMENT_ADRESSE.md](ENRICHISSEMENT_ADRESSE.md) | Phase 0 jamais terminée ; code cité supprimé |
| [analyse-updated-at-lieu-inclusion.md](analyse-updated-at-lieu-inclusion.md) | Résolu par V115 / V116 |
| [../spec-couche-source.md](../spec-couche-source.md) | Couche bronze livrée (V099) |
| [../visibilite_api_carto_20260914.md](../visibilite_api_carto_20260914.md) | À fusionner dans `cycle-de-vie-lieux-personnes-support.md` |

## Documentation dans les autres dépôts

| Dépôt | Où | Sujets |
|---|---|---|
| MIN (`anct-cnum/suite-gestionnaire-numerique`) | `docs/`, `docs/adr/` | Intégration MIN ↔ dataspace (migrations Prisma miroir), écran des postes CN, statistiques coop, membres de gouvernance (UI) |
| Nao (`incubateur-territoires/nao-context-inclusion-numerique`) | `RULES.md`, `agent/semantics/` | Contexte de l'agent LLM sur le schéma `llm` |
| Consommateurs du schéma | `CLAUDE.md`, section *Consommateurs du schéma* | Ce que chaque dépôt lit ou écrit, à vérifier avant une migration destructive |
