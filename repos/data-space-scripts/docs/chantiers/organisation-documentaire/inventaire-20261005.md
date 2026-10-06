# Inventaire documentaire — dataspace + MIN (2026-10-05)

> **Statut** : arbitrages A1, A2, A4, A5 rendus le 2026-10-05 (voir §3) — aucun fichier n'a encore été déplacé.
> **Périmètre** : 140 documents — dépôt dataspace (`docs/`, `approche-data/`, racine, README d'outils), fichiers non versionnés du checkout principal `~/Dev/dataspace`, dépôt MIN.
> **Méthode** : lecture de chaque document, confrontation au code et aux migrations (jusqu'à V177), date du dernier commit.

## Sommaire

1. [Synthèse](#1-synthèse)
2. [À traiter en priorité (indépendamment de la réorganisation)](#2-à-traiter-en-priorité)
3. [Arbitrages demandés](#3-arbitrages-demandés)
4. [Arborescence cible](#4-arborescence-cible)
5. [Inventaire — dataspace `docs/` et racine](#5-inventaire--dataspace-docs-et-racine)
6. [Inventaire — dataspace `approche-data/`](#6-inventaire--dataspace-approche-data)
7. [Inventaire — dataspace non versionné](#7-inventaire--dataspace-non-versionné-devdataspace)
8. [Inventaire — MIN](#8-inventaire--min)
9. [Doublons et recoupements à fusionner](#9-doublons-et-recoupements)
10. [Décisions à extraire en ADR](#10-décisions-à-extraire-en-adr)
11. [Plan de migration proposé](#11-plan-de-migration)

---

## 1. Synthèse

| | dataspace versionné | dataspace non versionné | MIN | Total |
|---|---|---|---|---|
| Documents | 88 | 29 | 23 | **140** |
| Référence / guide vivant | 22 | 0 | 9 | 31 |
| Référence **à rafraîchir ou obsolète** | 24 | — | 7 | 31 |
| Architecture (approche-data) | 13 | 2 (ancien DAT) | — | 15 |
| Travail (analyse, plan, audit…) | 20 | 17 | 3 | 40 |
| Prompts / brouillons à supprimer | — | 6 | 1 | 7 |
| Contenant des PII | 2 | 12 | 0 | 14 |

**Constats majeurs**

1. **La doc de référence décrit l'ancien modèle.** V148 (2026-07-30) a supprimé `main.structure` / `main.personne_affectations`, mais une douzaine de docs les présentent encore comme cible : `aidants-connect.md`, `conseillers-numeriques.md`, `coop.md` §Structures, `flux-globaux.md` §4, `id-poste-regles.md`, `questions-metier-en-cours.md`, `database/data_dict.md`… `cartographie-nationale.md` décrit encore `mednum-cli` alors que le DAG lit le fichier national. `approche-data/` n'a pas bougé depuis le 31/07 alors que V138→V177 ont été appliquées.
2. **Le cycle « analyse → décision → référence → archive » ne se ferme jamais.** 40 documents de travail, dont une vingtaine de chantiers clos, sans que leurs décisions ne remontent : **~35 décisions actées** n'existent que dans des notes de travail (§10).
3. **Pas d'index fiable.** `docs/README.md` ignore 18 des 33 docs de `docs/`, tout `approche-data/`, et annonce comme « MR en cours » un doc mergé en juin.
4. **Les documents non versionnés portent l'essentiel de l'historique du chantier #1724** (besoin, argumentaire, contrats coop, analyses mednum) et de la canonisation des structures — invisibles pour l'équipe.
5. **Les liens morts** : 6 docs inexistants référencés, une dizaine de fichiers de code disparus cités, et un lien mort dans le code MIN.
6. **MIN est mieux tenu** (ADR en place, format réutilisable) mais ses 5 ADR sont restés « En discussion » alors que tout est en œuvre, et 4 docs recoupent dataspace (postes CN, intégration, membres de gouvernance, droits BDD).

---

## 2. À traiter en priorité

Ces points ne dépendent pas de la réorganisation : ils sont à corriger même si rien d'autre n'est fait.

| # | Problème | Où | Action |
|---|---|---|---|
| P1 | **Email nominatif et téléphone réels dans un exemple JSON**, dépôt public | dataspace `docs/CONTACT_MERGE.md` l.11-16 | Remplacer par des valeurs fictives ; évaluer la purge de l'historique git |
| P2 | **Deux emails nominatifs d'agents d'une collectivité**, dépôt public | dataspace `docs/refonte-structure-plan.md` l.474 | Remplacer par la fonction / un compte |
| P3 | Informations d'accès sensibles (procédure d'accès prod, lien de partage Drive, URL internes) dans un dépôt public | MIN `CONTRIBUTING.md` §4 et §Accès production | Retirer du dépôt (secrets → gestionnaire de secrets), laisser un renvoi |
| P4 | Procédure « import des données locales » cassée des deux côtés : le DAG d'export pseudonymisé a été supprimé en V177 | MIN `CONTRIBUTING.md` §4, `docs/integration-dataspace.md` | Décider du remplaçant, puis une seule doc côté dataspace (`DEV_SETUP.md`) |
| P5 | Lien mort dans le code vers un doc dataspace inexistant | MIN `src/use-cases/queries/RechercherMembresAConsolider.ts:10` | Pointer vers `min/docs/constat-membres-gouvernance-mal-raccroches.md` |
| P6 | Correctif de droits `GRANT USAGE ON SCHEMA min TO min_scalingo` identifié mais jamais porté en migration | MIN `docs/audit-droits-bdd.md` (non versionné) | Ticket + migration Flyway |
| P7 | Journal des modifications de données (205 lignes, 13 emails) + sa copie Grist : abandonnés (A4) mais toujours présents | `~/Dev/dataspace/journal_modifications_donnees.md` (+ `.html`, `journal_canonisation_structures.md`), document Grist de synchronisation, branche `1670-sync-journal-grist` | Supprimer les fichiers locaux, le document Grist et la branche |
| P8 | `CLAUDE.md` cite black / reorder-python-imports / autoflake ; le pre-commit réel est ruff | dataspace `CLAUDE.md` §Code Quality | Corriger (les agents s'y fient) |

---

## 3. Arbitrages

### Rendus (2026-10-05)

| # | Question | Décision |
|---|---|---|
| A1 | Arborescence cible (§4) | **Validée, uniformisée** dans MIN et dataspace |
| A2 | Format ADR commun | **Validé** : format MIN + champs Périmètre, Tickets/MR, Remplace / Remplacé par ; index + modèle ; numérotation par dépôt |
| A4 | Journal des modifications de données | **Abandonné** : pas de journal détaillé. La traçabilité passe par le ticket, le script versionné (`scripts/`, sans PII) et l'entrée de CHANGELOG |
| A5 | Docs contenant des données personnelles | **On ne stocke pas de données privées.** Pas d'« espace privé » de repli : les docs à PII massives sont supprimés (les listes se régénèrent par requête, les critères restent dans le ticket) ; les docs à PII légères (prénoms) sont anonymisés (rôles) puis versionnés |

Conséquences : la colonne « espace privé » des §7-8 devient « supprimer » ou « anonymiser ». Seul le DAT reste hors dépôt (docs.numerique.gouv.fr, non personnel). Les informations d'accès sensibles (P3) sortent du dépôt sans être recopiées ailleurs que dans le gestionnaire de secrets.

### En attente

| # | Question | Proposition |
|---|---|---|
| A3 | Dépôt propriétaire des docs transverses (droits BDD, propriété des schémas, contrats inter-systèmes, données des postes CN, qualité des structures) | dataspace ; MIN garde la doc UI et un lien |
| A6 | `approche-data/` : abandonner la numérotation 01-22 et scinder | Oui : architecture / adr / chantiers (§6) |
| A7 | Références obsolètes : réécrire ou archiver | Réécrire `cartographie-nationale`, `coop-metier`, `enrichissement` ; archiver `api-carto-structures-regles` |
| A8 | Jumeaux tech / métier | Garder, suffixe `-metier` partout |

---

## 4. Arborescence cible

```
README.md, CHANGELOG*.md, CLAUDE.md, CONTRIBUTING.md   ← seuls .md à la racine
docs/
  README.md          index unique, point d'entrée (+ section « Doc dans les autres dépôts »)
  guides/            runbooks, how-to
  reference/
    sources/         un doc par source (tech + -metier)
    regles/          règles métier transverses (cycle de vie, survivance, id-poste, contacts)
    api/             PostgREST, contrats de sortie
  architecture/      principes et cible (ex-approche-data)
  adr/               ADR — NNN-titre.md (nom repris de MIN)
  chantiers/
    <ticket>-<sujet>/  docs de travail datés ; archivé à la clôture
  archive/
```

Conventions : `kebab-case.md` ; date `AAAAMMJJ` seulement pour les docs de travail ; ticket en préfixe du dossier de chantier ; en-tête obligatoire (statut, public, mise à jour, ticket, remplacé par). Chemins à préserver ou à mettre à jour ensemble : `docs/cycle-de-vie-lieux-personnes*.md` + `cycle-de-vie.gardes.yml` + skill `regles-lieux-personnes`.

Légende des tableaux — **Type** : réf (référence), guide, archi (architecture), déc (décision), trav (travail), hors-doc. **État** : ✅ vivant · 🔄 à rafraîchir · ⛔ obsolète · 🚧 chantier en cours · ✔️ chantier clos · ♻️ remplacé. **PII** : 🔒 oui.

---

## 5. Inventaire — dataspace `docs/` et racine

| Document | Lignes | Màj | Type | État | Destination | Note |
|---|---|---|---|---|---|---|
| docs/README.md | 99 | 09-13 | réf | 🔄 | rester (refondre en index) | 18/33 docs absents ; entrées mortes (§9) |
| docs/aidants-connect.md | 286 | 07-30 | réf | 🔄 | reference/sources/ | §Modèle cible `main.structure` ; loader écrit `structure_administrative` |
| docs/aidants-connect-metier.md | 69 | 05-01 | réf | 🔄 | reference/sources/ | « Évolutions avril 2026 » non revues |
| docs/analyse-updated-at-lieu-inclusion.md | 99 | 06-25 | trav | ✔️ | archive/ | Résolu par V115/V116 → ADR D-17 |
| docs/api-carto-structures-regles.md | 239 | 07-30 | réf | ⛔ | archive/ | Figé à V061-V063 ; remplacé par cycle-de-vie §2.4/3.5 ; 2 liens morts |
| docs/audit-adresse-canonique-sirene.md | 125 | 06-03 | trav | 🚧/✔️ ? | chantiers/1534-adresse-canonique/ | Doc pivot du chantier ; y fusionner l'état des lieux |
| docs/cartographie-nationale.md | 200 | 09-18 | réf | ⛔ | reference/sources/ (réécrire) | Décrit `mednum-cli` ; DAG = fichier national |
| docs/cartographie-nationale-metier.md | 47 | 05-01 | réf | 🔄 | reference/sources/ | Renvoie à une « MR en cours » mergée en juin |
| docs/ci-cd-orchestrator.md | 166 | 03-26 | guide | ✅ | guides/ | |
| docs/conseillers-numeriques.md | 284 | 05-01 | réf | 🔄 | reference/sources/ | `main.structure` ; chemin de code déplacé |
| docs/conseillers-numeriques-metier.md | 66 | 05-01 | réf | 🔄 | reference/sources/ | |
| docs/CONTACT_MERGE.md | 97 | 08-28 | réf | 🔄 🔒 | reference/regles/contact.md | **P1** ; §similarities caduc ; V164 lit `coop.users` |
| docs/coop.md | 411 | 08-28 | réf | 🔄 | reference/sources/ | En-tête à jour ; §Structures (l.116-240) caduc depuis V159 ; blocs #ticket = décisions |
| docs/coop-metier.md | 107 | 05-01 | réf | ⛔ | reference/sources/ (réécrire) | « trois familles » importées — faux depuis V144/V159 |
| docs/cycle-de-vie-lieux-personnes.md | 640 | 09-25 | réf | ✅ | reference/regles/ | Doc pivot (skill + gardes.yml en dépendent) |
| docs/cycle-de-vie-lieux-personnes-preuves.md | 312 | 09-25 | réf | ✅ | reference/regles/ | Matrice assertion → preuve |
| docs/cycle-de-vie-lieux-personnes-support.md | 385 | 09-22 | guide | ✅ | reference/regles/ (renommer `-metier`) | Absorbe `visibilite_api_carto_20260914.md` |
| docs/DEV_SETUP.md | 582 | 09-30 | guide | ✅ | guides/dev-setup.md | Absorbe la section PostgREST du README racine |
| docs/ENRICHISSEMENT_ADRESSE.md | 331 | 06-12 | trav | ⛔ | archive/ | Phase 0 jamais finie ; cite `structure_enrichment.py` (supprimé) |
| docs/enrichissement-sirene-ban.md | 187 | 05-01 | réf | ⛔ | reference/sources/enrichissement.md (réécrire) | Ignore les caches V137 / `enrichment_cache.py` |
| docs/etat-des-lieux-adresse-canonique.md | 93 | 06-03 | trav | 🚧/✔️ ? | fusionner dans l'audit | Doublon partiel de l'audit |
| docs/fix-ingestion-ac-geocodage-cp.md | 64 | 06-03 | trav | ✔️ | chantiers/1534-adresse-canonique/ | Fix `1c114be` livré → ADR D-18 |
| docs/flux-globaux.md | 531 | 09-30 | archi | 🔄 | architecture/ | §4 matrice sur `main.structure` ; passages V157 |
| docs/fusion-structures-synthese-po.md | 186 | 06-03 | trav | ✔️ | chantiers/refonte-structure/ | Vue métier ; « 6 décisions à instruire » à faire trancher |
| docs/id-poste-regles.md | 135 | 06-16 | réf | 🔄 | reference/regles/ | §2-3 sur `main.structure` ; §6 = règle durable |
| docs/plan-correction-adresses-ac-suite.md | 81 | 06-03 | trav | 🚧 ? | chantiers/1534-adresse-canonique/ | Option A vs B à trancher |
| docs/POSTGREST.md | 502 | 09-30 | réf | ✅ | reference/api/postgrest.md | Référence unique API |
| docs/questions-metier-en-cours.md | 329 | 05-01 | trav | 🔄 | chantiers/questions-metier/ | Q2-Q6, Q9, Q20-21 caduques — purger |
| docs/refonte-structure-metriques.md | 116 | 05-28 | trav | ✔️ | chantiers/refonte-structure/ → archive | Lien mort |
| docs/refonte-structure-phase-3-test.md | 125 | 05-28 | guide | ✔️ | archive/ | |
| docs/refonte-structure-plan.md | 1147 | 09-30 | trav | 🚧 🔒 | chantiers/refonte-structure/ | **P2** ; §Décisions tranchées → ADR D-12..15 ; N-items ouverts (#2013) |
| docs/regles-survivance.md | 160 | 07-29 | réf | 🔄 | reference/regles/survivance.md | État de fait ; retirer §similarities ; lier approche-data/18 et 20 |
| docs/subventions-conseiller-numerique.md | 782 | 03-24 | réf | 🔄 | reference/regles/ | « CSV intermédiaire » caduc ; source unique des subventions (absorbe MIN) |
| Apache_Airflow_Mattermost_Notifications.md | 70 | 2025-01 | guide | ✅ | guides/notifications-mattermost.md | |
| analyse_bascule_vue_union_v153.md | 176 | 08-20 | trav | ✔️ | chantiers/1724-lieux-inclusion/ | Exemple canonique d'analyse → ADR D-26 |
| spec-couche-source.md | 227 | 06-08 | trav | ✔️ | archive/ | Livré (V099) → ADR D-01 |
| visibilite_api_carto_20260914.md | 26 | 09-15 | trav | ♻️ | supprimer après fusion dans cycle-de-vie-support §5 | |
| README.md | 399 | 07-29 | réf | ⛔ | rester (réduire à un point d'entrée) | §Reconciliate et CSV caducs ; doublon POSTGREST |
| CONTRIBUTING.md | 59 | 07-29 | guide | 🔄 | rester | « Airflow 2.x/3.x » ; lien factice |
| contracts/README.md | 47 | 07-27 | réf | 🔄 | rester | « aucune validation branchée » — faux (mode warn) |
| database/data_dict.md | 2447 | 09-30 | réf | ⛔ | rester (régénérer) | Liste des tables supprimées ; aucun script de régénération versionné |
| scripts/README.md | 53 | 05-20 | guide | 🔄 | rester | 1 script documenté sur des dizaines |
| tests/README.md | 218 | 09-15 | guide | 🔄 | rester | Chemin absolu local ; lien mort |
| tests-unitaires/README.md | 53 | 07-28 | guide | ✅ | rester | |
| tools/delta-rapport/README.md | 66 | 07-01 | guide | ✅ | rester | |
| tools/menage-doublons-lieux/README.md | 49 | 07-08 | guide | ✔️ | rester ou archiver avec l'outil | One-shot caduc |
| tools/recale-dates-maj-lieux/README.md | 36 | 07-16 | guide | ✅ | rester | |
| .claude/skills/*/SKILL.md (10) | — | — | hors-doc | ✅ | rester | Emplacement imposé par l'outillage |

---

## 6. Inventaire — dataspace `approche-data/`

Aucune fiche n'a été mise à jour depuis le 31/07 (sauf 01 et 19 le 28/08) ; toutes les sections « État actuel » décrivent l'existant d'avant V127.

| Fiche | Lignes | Type | État | Destination | Note |
|---|---|---|---|---|---|
| README.md | 116 | archi | 🔄 | architecture/README.md | Garder cible + 6 principes ; diagnostic en 12 constats → archive |
| 01-architecture-medallion | 154 | archi | ✅ cible implémentée | architecture/ | « État actuel » à réécrire ; exception coop → ADR D-02 |
| 02-data-contracts | 120 | archi | partiellement implémenté | architecture/ | Mode warn branché, pas fail/quarantine |
| 03-qualite-donnees | 161 | archi | partiellement implémenté | architecture/ + chantiers/qualite/ | `staging.rejets` fait ; tests SQL non bloquants |
| 04-mdm-reconciliation | 160 | archi | 🔄 | architecture/ | Cite les DAGs similarities décommissionnés |
| 05-transformations-elt-dbt | 162 | déc | 🚧 (0 code) | adr/ + architecture/ | ADR D-05 ; scinder décision / cible |
| 06-observabilite-lineage | 116 | archi | ✅ (cible non implémentée) | architecture/ | |
| 07-gouvernance-catalogue | 130 | archi | 🔄 | architecture/ | Ignore `data_dict.md`, schéma `llm` |
| 08-feuille-de-route | 142 | trav | 🔄 | chantiers/plateforme-data/ | Statuts périmés ; anti-objectifs → ADR D-12 |
| 09-historisation-scd | 153 | archi | ✅ | architecture/ | « Pas de SCD2 sur main » → ADR D-06 |
| 10-modelisation-gold | 145 | archi | 🔄 | architecture/ | Modèle d'avant refonte |
| 11-securite-acces | 169 | archi | ✅ (cible non implémentée) | architecture/ | Reçoit l'audit droits BDD (MIN) ; manque rôles `nao_ro`, `coop` |
| 12-api-data-produit | 162 | archi | partiellement implémenté | architecture/ | Registre consommateurs existe dans CLAUDE.md |
| 13-environnements-backfills-dr | 156 | archi | 🔄 | architecture/ | « rejouer impossible » faux depuis V099 ; ignore le DAG de backup |
| 14-panorama-pratiques-avancees | 250 | déc | ✅ | adr/ | Déjà au format ADR → D-12 |
| 15-pattern-flux-reference | 127 | archi | ✅ cible implémentée | architecture/ | Tableau de conformité entièrement périmé → archive |
| 16-architecture-code-fcis | 142 | déc | ✅ cible implémentée | adr/ + architecture/ | ADR D-04 |
| 17-plan-remise-au-propre | 87 | trav | ✔️ | archive/ | « Règles du jeu » → CONTRIBUTING |
| 18-cartographie-ecritures-gold | 715 | trav | 🔄 (photo 30/07) | chantiers/survivance-gold/ | Doublon de méthode avec `regles-survivance.md` sans lien croisé |
| 19-retention-bronze | 159 | trav | 🚧 (non implémenté) | chantiers/retention-bronze/ | ADR D-11 (statu quo assumé) |
| 20-decisions-survivance | 113 | trav | 🚧 (0 ligne tranchée) | chantiers/survivance-gold/ | Plusieurs lignes devenues sans objet (V157, #1724) |
| 21-conception-crosswalk | 225 | trav | 🚧 (spec, 0 code) | chantiers/crosswalk/ | C8 → ADR D-07 |
| 22-conception-overrides-min | 170 | trav | 🚧 (spec, 0 code) | chantiers/overrides-min/ | M2 → ADR D-08 ; incohérence avec 20 (T2 « acté » vs ☐) |

Avancement de la feuille de route (08) d'après le code : étape 1 fondation **faite** (sauf alerte de drift) ; étape 2 qualité **en cours** (quarantaine faite, tests non bloquants) ; étape 3 lisibilité métier **bloquée** sur l'arbitrage survivance ; étape 4 industrialisation **partielle** (silver + caches faits, dbt non commencé) ; étape 5 pilotage **non commencée**. Le plan 17 est entièrement terminé.

---

## 7. Inventaire — dataspace non versionné (`~/Dev/dataspace`)

Décision A5 : PII massives → supprimer ; PII légères → anonymiser puis versionner.

| Fichier | Ko | Type | Chantier | État | PII | Destination |
|---|---|---|---|---|---|---|
| analyse_1101_postes_structure_id_null.md | 3,5 | trav | MIN #1101 | 🚧 | — | chantiers/1101-postes-sans-structure/ |
| analyse_communes_mal_rattachees.md | 14,5 | trav | #1669 | partiellement clos | 🔒 2 emails | chantiers/1669-gouvernance-structures/ après retrait |
| analyse_comptes_coop_sans_role_emploi_actif.md | 10,8 | trav | MIN #1691 | ? | 🔒 massif (65 personnes) | supprimer |
| analyse_decrochages_sources.md | 24,1 | trav | #1681 | ✔️ | — | chantiers/1669-gouvernance-structures/ |
| analyse_dedup_mednum_cli_20260828.md | 24,6 | trav | #1724 | ✔️ | — | chantiers/1724-lieux-inclusion/ → ADR D-29 |
| analyse_defusions_dora_dora_20260828.md | 34,1 | trav | #1724 | ✔️ | 🔒 un prénom | chantiers/1724-lieux-inclusion/ après retrait |
| analyse_epci_restants.md | 11,7 | trav | #1681 | ✔️ | 🔒 massif (84 emails) | supprimer |
| analyse_expiration_mednum_20260909.md | 8,7 | trav | #1724 | ✔️ | — | chantiers/1724-lieux-inclusion/ ; reporter dans cartographie-nationale.md |
| analyse_structures_distinctes_gardees.md | 35,3 | trav | #1681 | ✔️ | 🔒 massif (~183 emails) | supprimer |
| ancienDAT/DAT.md (+ MCD, schéma) | 5,8 | archi | DAT | ⛔ | 🔒 noms équipe | supprimer (le DAT à jour vit sur docs.numerique.gouv.fr) |
| ancienDAT/Registre_données.md | 4,9 | archi | DAT | ⛔ | — | reprendre l'utile dans flux-globaux.md, puis supprimer |
| argumentaire_lecture_directe_1724.md | 6,5 | déc | #1724 | ✔️ | — | chantiers/1724-lieux-inclusion/ → ADR D-25 |
| besoin_1724_lieux_inclusion.md | 37,7 | trav | #1724 | 🚧 fin de cycle | 🔒 prénoms | chantiers/1724-lieux-inclusion/ après anonymisation → ADR D-27, D-28 |
| brouillon_1724_etat_des_lieux_li_20260728.md (+ .pdf) | 22,2 | brouillon | #1724 | ♻️ par besoin_1724 | — | supprimer |
| contrat_coop_ecriture_lieux_20260820.md | 5,0 | communication | #1724 | ♻️ par v2 | — | supprimer |
| contrat_coop_lieux_v2_20260909.md | 4,4 | communication | #1724 | ✔️ (en prod 11/09) | 🔒 prénoms | chantiers/1724-lieux-inclusion/ après anonymisation → ADR D-30..32 |
| diagnostic-1468-ac-upsert-ac_id.md | 11,9 | trav | #1468 | ✔️ | — | chantiers/1468-ancrage-identite-ac/ → ADR D-19 |
| journal_modifications_donnees.md | 89,7 | journal | #1669, #1573… | ✅ (205 entrées, 17/06→19/08) | 🔒 13 emails | supprimer (A4) |
| message_mednum_defusions_20260918.md | 4,2 | communication | #1724 | ? envoyé | — | chantiers/1724-lieux-inclusion/ ou issue #1855 |
| point_etape_appariements_20260826.md | 4,7 | trav | #1724 | ♻️ (instantané) | 🔒 prénoms, id GitHub | chantiers/1724-lieux-inclusion/ après anonymisation → ADR D-33 |
| prompt_coop_registre_lieux_20260909.md | 6,4 | prompt | #1724 | consommé | — | supprimer |
| prompt_coop_renommage_lieu_inclusion_20260910.md | 3,3 | prompt | #1724 | consommé | — | supprimer |
| prompt_coop_verification_finale_20260911.md | 6,3 | prompt | #1724 | consommé | — | supprimer |
| prompt_exploration_expiration_mednum.md | 2,7 | prompt | #1724 | consommé | — | supprimer |
| rapport_rerattachement_membres_2026-06-24.md | 4,7 | trav | #1669 | ✔️ | 🔒 utilisateurs MIN | supprimer ; règle → ADR D-20 |
| rapport_structures_administratives_2026-07-07.md | 11,9 | trav | #1669/#1681 | ✔️ (§7 ouvert) | — | chantiers/1669-gouvernance-structures/ ; §7 → issues |
| reponse_&lt;prénom&gt;_fusions_20260709.md | 19,2 | communication | coop #1707 | ? | 🔒 prénom (nom de fichier) | anonymiser → `retour-coop-fusions-20260709.md` |

Fichiers associés également non suivis : `journal_modifications_donnees.html`, `journal_canonisation_structures.md` (cité par le rapport du 07/07).

---

## 8. Inventaire — MIN

| Document | Lignes | Màj | Type | État | Propriétaire | Destination | Note |
|---|---|---|---|---|---|---|---|
| README.md | 50 | 05-25 | guide | ✅ | min | rester | Liste des schémas dataspace incomplète → lien vers dataspace |
| CONTRIBUTING.md | 437 | 09-10 | guide | 🔄 | min | rester (alléger vers docs/guides/) | **P3**, **P4** |
| CLAUDE.md, .claude/skills/* (4), .github/pull_request_template.md | — | — | hors-doc | ✅ | min | rester | |
| docs/SEO-VITRINE.md | 537 | 2025-12 | réf | 🔄 | site vitrine (code dans min) | docs/reference/vitrine/ | À confronter aux routes actuelles |
| docs/adr/001…005 | 40-69 | 04-01 | déc | ✅ mais statut faux | min | rester | Tous « En discussion » alors qu'en œuvre → « Accepté » ; ADR Biome annoncé jamais écrit |
| docs/constat-membres-gouvernance-mal-raccroches.md | 383 | 06-17 | trav | 🚧 | transverse | docs/chantiers/membres-gouvernance/ | **P5** ; recoupe 3 docs non versionnés dataspace |
| docs/couche-anticorruption-statistiques.md | 336 | 04-14 | archi | 🔄 | min | docs/reference/statistiques-coop.md | Cite `main.activites_coop` ; lit désormais `coop.activites` |
| docs/integration-dataspace.md | 122 | 05-25 | guide | 🔄 | min (procédure) / dataspace (schémas) | docs/guides/ ; matrice des schémas → lien | Références mortes (export supprimé V177) |
| docs/postes-conseiller-numerique.md | 373 | 09-07 | réf | 🔄 | min (écran) / dataspace (règles) | docs/reference/ (écran seul) | **SQL faux** vs la vue réelle ; contredit `subventions-conseiller-numerique.md` |
| scripts/README.md | 493 | 04-01 | guide | 🔄 | min | index court + docs/guides/ | 3 scripts non documentés |
| src/gateways/apiCoop/exemple-utilisation.md | 421 | 04-01 | guide | 🔄 | min | fusionner dans docs/reference/statistiques-coop.md | Clarifier API vs SQL `coop.*` |
| docs/audit-droits-bdd.md (non versionné) | 197 | 07-15 | trav | 🚧 | dataspace | dataspace chantiers/ (sans topologie prod) | **P6** ; topologie infra à ne pas publier |
| docs/nettoyage-structures-administratives.md (non versionné) | 109 | 06-22 | trav | 🔄 | transverse | min chantiers/ (volet UI) | En partie périmé (V148) |
| test.md (non versionné) | 0 | — | — | — | — | supprimer | |

---

## 9. Doublons et recoupements

| # | Groupe | Document de référence retenu | Sort des autres |
|---|---|---|---|
| G1 | Visibilité / cycle de vie carto | `cycle-de-vie-lieux-personnes.md` (+ `-metier`, `-preuves`) | `api-carto-structures-regles` → archive ; `visibilite_api_carto_20260914` absorbé puis supprimé ; POSTGREST garde le contrat d'API |
| G2 | Survivance | `regles-survivance.md` (état de fait) | approche-data/18 et 20 → chantier survivance-gold ; chaque ligne tranchée → ADR |
| G3 | Enrichissement SIRENE / BAN | nouveau `reference/sources/enrichissement.md` (caches V137) | `ENRICHISSEMENT_ADRESSE` → archive ; `enrichissement-sirene-ban` réécrit |
| G4 | Adresse canonique #1534 | `audit-adresse-canonique-sirene.md` | état des lieux fusionné ; plan + fix dans le même dossier chantier |
| G5 | Refonte structure | `refonte-structure-plan.md` | métriques, phase-3 → archive ; synthèse PO = vue métier ; décisions → ADR |
| G6 | Conseillers numériques / postes | `conseillers-numeriques.md` + `subventions-conseiller-numerique.md` (dataspace) | `id-poste-regles` → regles/ ; **MIN `postes-conseiller-numerique.md` réduit à l'écran + lien** |
| G7 | Couche source | approche-data/01 + 15 | `spec-couche-source.md` → archive |
| G8 | Flux et écritures | `flux-globaux.md` (topologie) + approche-data/18 (écritures gold) | purger V157 et §4 ; MIN `integration-dataspace` pointe vers dataspace |
| G9 | PostgREST / setup | `POSTGREST.md` + `DEV_SETUP.md` | README racine réduit à des liens |
| G10 | Contacts | `cycle-de-vie` §3.7 | `CONTACT_MERGE` réduit à une fiche JSONB anonymisée |
| G11 | Gouvernance / structures administratives | dossier `dataspace/docs/chantiers/1669-gouvernance-structures/` | MIN `constat-membres…` et `nettoyage-structures…` gardent le volet UI + lien |
| G12 | Droits BDD | approche-data/11 (matrice) | MIN `audit-droits-bdd` → chantier dataspace |
| G13 | Statistiques coop (MIN) | `min/docs/reference/statistiques-coop.md` | fusion couche anticorruption + exemple-utilisation |

**Liens morts** à corriger : `api-carto-regles.md`, `main-structure-regles.md`, `refonte-structure-modelisation.md`, `besoin_1724_lieux_inclusion.md` (non versionné), `etl/README-IdPoste.md`, `dataspace/docs/constat-membres-gouvernance-mal-raccroches.md` (depuis le code MIN). Plusieurs docs renvoient aussi à des **mémoires d'agent privées** (`[[…]]`, « cf mémoire ») introuvables pour un lecteur humain : à remplacer par le contenu ou un lien versionné.

**Nommage** : 4 fichiers en MAJUSCULES (`CONTACT_MERGE`, `DEV_SETUP`, `ENRICHISSEMENT_ADRESSE`, `POSTGREST`) ; trois suffixes métier (`-metier`, `-support`, `-synthese-po`) ; `conseillers-numeriques` / `subventions-conseiller-numerique` / `id-poste` / `schema-idPoste` pour le même dispositif ; préfixes de travail hétérogènes sans ticket.

---

## 10. Décisions à extraire en ADR

Numérotation provisoire. Propriétaire : dataspace sauf mention.

| # | Décision | Source |
|---|---|---|
| D-01 | Bronze append-only, JSONB brut, capture non intrusive (strangler fig) | spec-couche-source, approche-data/01 |
| D-02 | Pas de bronze / silver pour une source du même cluster (coop) | approche-data/01, V159 |
| D-03 | Pattern « bronze d'abord », la base comme interface (`run_id`, `source_key`), ni XCom ni CSV | approche-data/15 |
| D-04 | FCIS retenu, hexagonal écarté | approche-data/16 |
| D-05 | dbt Core pour silver → gold, mise en œuvre conditionnée | approche-data/05 |
| D-06 | Pas de SCD2 sur `main` : audit_trail + snapshots dataviz | approche-data/09 |
| D-07 | Crosswalk dans un schéma dédié | approche-data/21 (C8) |
| D-08 | Silver des overrides MIN | approche-data/22 (M2) |
| D-09 | Caches d'enrichissement accumulés, TTL 4 mois, silver ⋈ caches | approche-data/08, 17 |
| D-10 | Géocodage score &lt; 0,5 rejeté ; ordre idposte → AC → coop | approche-data/17 |
| D-11 | Rétention bronze : statu quo assumé | approche-data/19 |
| D-12 | Pratiques avancées non retenues + anti-objectifs, avec signaux de bascule | approche-data/14, 08 |
| D-13 | Qualité : SQL pur / `SQLCheckOperator` d'abord (à confirmer) | approche-data/03 |
| D-14 | Hygiène : ruff seul, mypy sur `etl/core/`, uv | approche-data/17 |
| D-15 | Antennes via `denomination_antenne` ; un canonique par SIRET | refonte-structure-plan §Décisions |
| D-16 | Deux tables d'affectation (emploi / lieu) ; bascule big bang | refonte-structure-plan §Décisions |
| D-17 | `updated_at` du lieu = GREATEST des `updated_at_<source>` | analyse-updated-at-lieu-inclusion |
| D-18 | Géocodage AC filtré sur le code postal (INSEE source pollué) | fix-ingestion-ac-geocodage-cp |
| D-19 | Ancrage d'identité AC : création normalisée + redirection perdant → gagnant | diagnostic-1468 |
| D-20 | Règle « l'id membre encode la vérité » (département / commune → structure) | analyses gouvernance #1669 |
| D-21 → D-24 | Les « 6 décisions à instruire » de la fusion des structures | fusion-structures-synthese-po (à faire trancher) |
| D-25 | Lecture directe (vue) plutôt que réplication datée | argumentaire_lecture_directe_1724 |
| D-26 | Posture transitoire de l'export public pendant la bascule | analyse_bascule_vue_union_v153 §6 |
| D-27 | Modèle cible des lieux = agrégation de 3 listes ; fin de l'import API coop | besoin_1724 §4 |
| D-28 | Garbage collector des lieux orphelins | besoin_1724, journal (19/08) |
| D-29 | Appariement indexé par segment, jamais par id composite | analyse_dedup_mednum_cli |
| D-30 | `source` = provenance des valeurs affichées | contrat_coop_lieux_v2 |
| D-31 | La coop écrit le registre en double écriture applicative (transverse dataspace / coop) | contrat_coop_lieux_v2 |
| D-32 | Le cycle de vie carto ne touche pas les lignes coop | contrat_coop_lieux_v2 |
| D-33 | L'interface de revue des appariements est le seul canal de décision (pas de pré-validation automatique) | point_etape_appariements |
| D-34 | Contrat idposte actif = `date_rupture IS NULL` seul | consigne 2026-09-14, à formaliser |
| MIN | Passer ADR-001…005 en « Accepté » ; écrire ou retirer l'ADR Biome | min/docs/adr |

---

## 11. Plan de migration

Une MR par étape, chacune relisible isolément.

| Étape | Contenu | Dépend de |
|---|---|---|
| 0 | **Priorités P1-P8** (PII, liens morts, droits, CLAUDE.md) | — |
| 1 | Créer l'arborescence + modèle d'ADR + nouvel index `docs/README.md` ; règle de cycle de vie dans CLAUDE.md | A1 ✅, A2 ✅ |
| 2 | **Déplacements purs** (`git mv`) + correction des liens, sans réécriture ; mettre à jour skill `regles-lieux-personnes` et `cycle-de-vie.gardes.yml` | 1 |
| 3 | Rapatrier les non-versionnés : anonymiser → `chantiers/` ; supprimer prompts, brouillons, docs à PII massives, journal | A4, A5 ✅ |
| 4 | Fusions G1-G13, une MR par groupe | 2 |
| 5 | Extraction des ADR D-01…D-34 (par lots thématiques) | 1 |
| 6 | Réécritures des références obsolètes (carto, coop-metier, enrichissement, sources sur `structure_administrative`, `data_dict` régénéré) | 4 |
| 7 | MIN : même arborescence, ADR passés en « Accepté », docs transverses réduits à des liens | A3 |
| 8 | CI : liens cassés, en-tête obligatoire, doc absent de l'index | 1 |
