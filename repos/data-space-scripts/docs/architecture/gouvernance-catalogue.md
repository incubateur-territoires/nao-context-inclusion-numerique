# 07 — Gouvernance : dictionnaire de données, ownership, données personnelles

← [Retour au document central](README.md)

## Le concept

La gouvernance data répond à trois questions que la technique seule ne résout pas :

1. **Que signifie cette donnée ?** → dictionnaire de données / catalogue
2. **Qui en est responsable ?** → ownership / stewardship
3. **A-t-on le droit de la traiter ainsi ?** → conformité (RGPD en tête, projet public oblige)

À l'échelle de ce projet (équipe réduite, beta.gouv), la gouvernance n'est pas une
bureaucratie : c'est **quelques documents vivants et quelques rôles explicites**. Le test
décisif : un nouveau venu (dev, PO, partenaire API) peut-il comprendre une donnée sans
interroger quelqu'un ?

## État actuel du projet

- Pas de dictionnaire de données : la signification de `main.structure.statut` ou des
  champs exposés par `api.carto` vit dans les têtes et dans le code.
- Les partenaires qui consomment l'API PostgREST interprètent les champs sans référence —
  chaque partenaire peut comprendre différemment le même champ.
- Ownership implicite : "l'équipe" est responsable de tout, donc personne d'un flux en
  particulier.
- Données personnelles : des personnes (médiateurs, aidants) sont en base avec nom, email,
  visibilité. Des précautions existent (pseudonymisation du jeu de dev `--with-data`,
  règle "pas de noms dans CHANGELOG-metier"), mais pas de registre formalisé des données
  personnelles ni de doctrine de minimisation par couche.

## Mise en place sur ce projet

### 1. Dictionnaire de données — commencer par les interfaces

Prioriser les données **exposées** (là où le coût d'un malentendu est maximal) :

1. Les vues `api.*` (consommées par des partenaires externes) ;
2. Les tables `main.*` (consommées par MIN) ;
3. `dataviz` ensuite, `staging`/`source` en dernier (publics internes).

Format : le plus simple qui sera réellement maintenu. Deux options complémentaires :

- **`COMMENT ON` en base**, dans les migrations Flyway :
  ```sql
  COMMENT ON COLUMN api.carto.statut IS
    'Statut d''activité de la structure. Valeurs : active | fermee | en_creation. Source : coop, sinon carto.';
  ```
  Avantage décisif : PostgREST expose les comments dans son OpenAPI, Metabase les affiche,
  `dbt docs` les reprend — **une seule saisie, visible partout**. C'est l'option recommandée.
- Un markdown `docs/reference/dictionnaire/` seulement pour ce qui dépasse le commentaire
  (règles de calcul complexes, historique des changements de sémantique).

Chaque définition indique : signification métier, valeurs possibles, source(s) et règle de
survivance (lien fiche 04), caractère personnel ou non.

**Règle d'équipe** : une MR qui ajoute/modifie un champ exposé inclut son `COMMENT ON` —
au même titre que l'entrée CHANGELOG déjà obligatoire.

### 2. Ownership léger

Pas de comité, juste un tableau dans le README du dossier :

| Domaine | Owner (rôle) | Répond à |
|---------|--------------|----------|
| Flux carto | un dev désigné | contrat, qualité, incidents de ce flux |
| Flux coop | ... | ... |
| Règles de réconciliation | PO + dev | arbitrages de survivance, revue des fusions |
| API publique | PO | compatibilité, communication partenaires |
| Données personnelles | référent désigné | registre, demandes d'exercice de droits |

L'owner n'est pas celui qui fait tout : c'est celui qui **sait** et qui **décide** en
premier ressort. La revue humaine MDM (fiche 04) donne au métier un rôle opérationnel
concret — c'est la meilleure gouvernance : celle qui s'exerce dans un outil, pas dans
des réunions.

### 3. Données personnelles — minimisation par couche

Doctrine simple, alignée avec l'architecture en couches (fiche 01) :

| Couche | Contenu personnel | Règle |
|--------|-------------------|-------|
| `source` (bronze) | Tel que reçu | Accès restreint aux rôles pipeline ; rétention définie et documentée |
| `staging` | Nécessaire au traitement | Accès équipe data uniquement |
| `main` | Minimisé au besoin de MIN | Base légale et finalité documentées par champ personnel |
| `api` / `dataviz` | **Le strict minimum** | Chaque champ personnel exposé est une décision explicite ; respect systématique des choix de visibilité (l'incident `is_visible` est le contre-exemple fondateur) |

Actions concrètes :

- **Registre des données personnelles** : un tableau (champ, finalité, base légale, durée
  de rétention, où il est exposé) — exigé par le RGPD, et de toute façon utile.
- **Propagation des suppressions** : si une personne disparaît d'une source ou exerce ses
  droits, la suppression doit se propager jusqu'à `main`, `api`, `dataviz`… et poser la
  question de la couche bronze append-only (exception documentée : purge ciblée du brut
  sur demande d'exercice de droits — l'append-only souffre les exceptions légales).
- Les choix d'exposition (quel champ personnel dans quelle vue `api`) sont revus par le
  référent, pas décidés au fil des MR.

### 4. Documentation des règles métier

Les fiches 02 (contrats) et 04 (survivance) produisent les documents de gouvernance les
plus importants. S'y ajoutent, déjà en place et à maintenir :

- `CHANGELOG.md` / `CHANGELOG-metier.md` — la double écriture tech/métier est une
  excellente pratique de gouvernance, la garder ;
- le dossier `docs/architecture/` comme point d'entrée de la doctrine.

## Par où commencer

1. `COMMENT ON` sur toutes les colonnes des vues `api.*` (une migration, quelques heures,
   visible immédiatement par les partenaires via OpenAPI).
2. Tableau d'ownership dans ce dossier.
3. Registre des données personnelles (avec le référent).
4. Étendre les comments à `main`, puis au reste au fil de l'eau.

## Pièges connus

- **Le catalogue-outil avant le contenu** : déployer DataHub/OpenMetadata à cette échelle
  est un contresens — le contenu (définitions) est le travail, l'outil est secondaire.
  `COMMENT ON` + dbt docs suffisent très longtemps.
- **Le dictionnaire non maintenu** : d'où la règle "pas de MR de champ exposé sans comment"
  — la maintenance doit être structurelle, pas volontaire.
- **La gouvernance vécue comme un frein** : la présenter (et la construire) comme ce
  qu'elle est ici — moins de tickets, moins de malentendus partenaires, moins d'incidents
  type `is_visible`.

## Références

- DAMA DMBOK (chapitres Data Governance, Metadata) — la référence, à doser
- CNIL — registre des traitements, minimisation (obligations d'un projet public)
- PostgREST — exposition des `COMMENT ON` dans le schéma OpenAPI
