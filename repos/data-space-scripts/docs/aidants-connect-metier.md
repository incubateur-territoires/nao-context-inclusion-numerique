# Aidants Connect — vue métier

> Version non-technique de [`aidants-connect.md`](aidants-connect.md).
> Pour les détails d'implémentation, voir la documentation technique.

## En quelques mots

**Aidants Connect** est un dispositif national ANCT/Numérique de labellisation et d'accompagnement des aidants. Ces aidants sont des personnes qui accompagnent les usagers dans leurs démarches numériques administratives. Le dataspace en ramène deux entités principales : les structures habilitées (lieux où exercent les aidants) et les aidants labellisés (les accompagnatrices et accompagnateurs). Les affectations établissent le lien entre aidant et structure, avec un état actif ou inactif.

## Quelles données ramenées ?

Le dataspace importe trois types de données depuis Aidants Connect :

- **Organisations habilitées** — structures où les aidants exercent, avec identifiants (UUID), adresses et statut d'activité.
- **Aidants labellisés** — personnes accompagnatrices, avec identifiants, domaines de formation et nombre d'accompagnements réalisés.
- **Affectations** — liens aidant ↔ structure, marqués actif/inactif pour refléter les changements de statut.

## D'où viennent les données ?

L'API publique d'Aidants Connect (aidantsconnect.beta.gouv.fr) alimente le dataspace.

- **Organisations** : import complet quotidien (toutes les structures).
- **Aidants** : import incrémental quotidien à 5h du matin. Seules les modifications depuis le dernier import sont rapatriées, sauf au premier run (full fetch).
- **Mécanisme** : chaîne de validation automatisée, avec relances automatiques en cas d'échec et notifications sur Mattermost.

Les données remontées sont enrichies avec les référentiels français (SIRENE pour statuts administratifs, BAN pour adresses exactes et géolocalisation) avant insertion en base.

## Règles métier importantes

Quatre règles structurent comment les données Aidants Connect sont traitées :

### Désactivation par affectation (depuis février 2026)

Quand un aidant est **désactivé côté Aidants Connect**, ce n'est pas la personne globale qu'on marque comme inactive. À la place, **on désactive uniquement l'affectation** (le lien aidant ↔ structure).

**Pourquoi** : un aidant peut exercer dans plusieurs systèmes à la fois (Coop, CoNum, etc.). Si on le supprimait complètement, il disparaîtrait partout. En désactivant seulement l'affectation, il reste actif dans les autres structures où il travaille réellement.

### Label "France Services"

Si une structure est labellisée **France Services** côté Aidants Connect, on ajoute ce marqueur. **Important** : on ajoute le label, on ne remplace pas les autres labels existants (une structure peut en avoir plusieurs).

### Filtrage géographique pour éviter les homonymes (fix avril 2026)

L'API Aidants Connect fournit rarement le **code INSEE** (code officiel de la commune). Sans ce code, le système de géocodage français BAN peut associer la structure à une commune homonyme située dans un autre département. **Volume mesuré avant correction : environ 1 000 structures déportées dans le mauvais département.**

**Depuis avril 2026** : avant d'appeler le géocodeur BAN, le système **dérive le code INSEE** à partir du code postal et du nom de commune (via des référentiels administratifs). Le géocodeur peut alors utiliser ce filtre géographique pour trouver la bonne adresse.

### Structures sans nom ignorées

Les structures sans nom ne sont pas insérées en base.

## Évolutions récentes (avril 2026)

- **Filtrage géographique BAN** (29 avril, `2474f9c`) — ~1 000 structures avaient été géocodées dans le mauvais département (le géocodeur matchait une commune homonyme quand le code INSEE manquait). Voir règle "Filtrage géographique pour éviter les homonymes" plus haut pour le mécanisme appliqué depuis.

## Questions ouvertes côté métier

Avant de finaliser certaines intégrations, quelques points nécessitent clarification :

- **Périmètre de l'API** (`/fne_organisations/`) — retourne-t-elle **toutes** les structures (labellisées, en cours, désactivées) ou uniquement les actives ? Faut-il filtrer côté ETL ?
- **Cohérence du filtre incrémental** — quand on demande les aidants modifiés depuis une date, l'API remonte-t-elle aussi les structures liées modifiées dans la même fenêtre de temps, ou faut-il deux imports séparés ?
- **Code INSEE absent dans l'API** — est-ce une lacune systématique chez certaines structures (à corriger côté Aidants Connect) ou un cas métier normal (structures sans adresse stable) ?
- **Sémantique de `deleted_at`** — quand un aidant est désactivé, on utilise l'horodatage API. Préférable d'utiliser l'horodatage du dataspace (quand on reçoit la désactivation) pour distinguer "désactivé côté API à date X" vs "désactivé en base à date Y" ?

## Pour aller plus loin

- **Documentation technique détaillée** : [`aidants-connect.md`](aidants-connect.md)
- **Évolutions fonctionnelles du dataspace** : [`../CHANGELOG-metier.md`](../CHANGELOG-metier.md)
- **Questions transverses** : [`questions-metier-en-cours.md`](questions-metier-en-cours.md) (Q10-Q13)
