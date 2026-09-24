# Contrats de flux (data contracts)

> Un fichier YAML par flux entrant. Décrit ce que le pipeline **attend** de chaque source :
> schéma, sémantique, garanties, volumétrie. Voir [approche-data/02-data-contracts.md](../approche-data/02-data-contracts.md).

## Statut : documentaire

Ces contrats ne sont **pas exécutés** — aucune validation n'est branchée dans les DAGs à ce
stade. Ils servent de :

- description de référence de chaque flux (la seule hors code) ;
- base d'échange avec les équipes sources ("voici ce qu'on consomme") ;
- socle de la future validation en mode warn puis bloquant (étape 2 de la feuille de route).

## Méthode d'élaboration

Chaque contrat est établi par **rétro-ingénierie du code** (DAG + `etl/`) **croisée avec les
données réelles** (tables `source.*` et schémas aval en base). Les valeurs observées
(enums, volumétrie) sont datées. Le minimum d'hypothèses : ce qui n'a pas pu être vérifié
en base est marqué `verifie: false`.

## Conventions

- Nom de fichier : `{source}__{dataset}.yml` (aligné sur `source.{source}__{entite}`).
- `fields` décrit les champs **tels qu'envoyés par la source** (noms d'origine, chemins JSON
  explicites), pas nos colonnes après renommage.
- Section `observations` : constats datés issus des données réelles (volumétrie, enums).
- Section `hypotheses_implicites` : fragilités et suppositions découvertes dans le code —
  le livrable caché de l'exercice.
- Contrat modifié = MR revue + entrée `CHANGELOG.md` (le drift accepté est tracé).

## Flux couverts

| Contrat | Source | Statut |
|---|---|---|
| [frr__zonage.yml](frr__zonage.yml) | collectivites-locales.gouv.fr (XLSX) | rédigé |
| [qpv__zonage.yml](qpv__zonage.yml) | data.gouv.fr / ANCT (ZIP GeoJSON) | rédigé |
| [ac__structures.yml](ac__structures.yml) | API Aidants Connect | rédigé |
| [ac__aidants.yml](ac__aidants.yml) | API Aidants Connect | rédigé |
| [ac__accompagnements.yml](ac__accompagnements.yml) | API Aidants Connect (même endpoint que ac__aidants) | rédigé |
| [idposte__conum.yml](idposte__conum.yml) | export S3 conseillers numériques (CSV) | rédigé |
| [coop__structures.yml](coop__structures.yml) | API coop-numerique | rédigé |
| [coop__utilisateurs.yml](coop__utilisateurs.yml) | API coop-numerique | rédigé |
| [coop__activites.yml](coop__activites.yml) | API coop-numerique | rédigé |
| [carto__structures.yml](carto__structures.yml) | data.gouv.fr / mednum-cli (JSON gzip) | rédigé |
| [sirene__etablissements.yml](sirene__etablissements.yml) | API INSEE Sirene 3.11 | rédigé |
| [ban__adresses.yml](ban__adresses.yml) | API IGN Géoplateforme (BAN) | rédigé |
