# Coop — Vue métier

> Version non-technique de [`coop.md`](coop.md). Pour les détails d'implémentation (requêtes SQL, structures de tables, fonctions Python), voir la documentation technique.

## En quelques mots

Coop (CoopNumérique) est une plateforme regroupant les données des médiateurs numériques et de leurs lieux d'activité. Le dataspace en récupère quotidiennement trois familles d'informations : les **structures** (lieux d'activité, points de service), les **personnes** (médiateurs et coordinateurs), et les **activités** (événements de médiation enregistrés). Ces données sont enrichies avec la base SIRENE (données administratives des entreprises) et avec la géolocalisation, puis fusionnées avec les données d'autres sources (Conseillers Numériques, Aidants Connect, Cartographie nationale) pour offrir une vision complète et consolidée du secteur.

## Quelles données ramenées ?

### Structures (lieux d'activité)

Chaque structure est un lieu où se déploient des actions de médiation : mairie, association, bibliothèque, etc. Pour chaque structure, on récupère :
- Identité de base : nom, SIRET, numéro RNA
- Localisation : adresse complète (géocodée automatiquement)
- Profil : typologies, services offerts, publics visés, frais, formations dispensées
- Moyens : nombre de médiateurs en activité, postes d'emploi déclarés
- Contact et accès : horaires, modalités de prise de rendez-vous, présentation

### Personnes (médiateurs et coordinateurs)

Chaque personne est soit un médiateur (exerce l'activité de médiation), soit un coordinateur (anime une équipe), ou les deux. Pour chaque personne, on enregistre :
- Identité de base : nom, prénom
- Rôles : médiateur et/ou coordinateur
- Visibilité : peut-elle être affichée publiquement (par exemple sur une carte), ou souhaite-t-elle rester cachée
- Affectations : lieux où elle exerce, structures qui l'emploient
- Contact : numéro, email, autres coordonnées

### Activités

Les activités représentent les événements ou accompagnements enregistrés par les médiateurs. Elles sont en import incrémental : seules les mises à jour depuis la dernière exécution sont rapatriées.

### Coexistence avec d'autres sources

Les mêmes structures et personnes peuvent venir de plusieurs sources (Coop, Conseillers Numériques officiels, Aidants Connect, Cartographie nationale). Le dataspace ne crée pas de doublons : il reconnaît les mêmes entités selon leur SIRET (pour les structures), ou des identifiants partagés (pour les personnes), et les unifie en une seule ligne avec leurs données complétées des différentes sources.

## D'où viennent les données ?

L'API REST de Coop expose sept endpoints publics. Le dataspace en importe régulièrement trois :

| Donnée | Endpoint | Fréquence | Notes |
|---|---|---|---|
| Structures | `/structures` | Quotidien, 8h | Aucune pagination ; paginé en interne (500 par page) |
| Personnes | `/utilisateurs` | Quotidien, 8h | Inclut leurs lieux d'activité en ligne |
| Activités | `/activites` | Quotidien, 8h | Incrémental via horodatage ; rafraîchi par batch de 500K |

Deux autres endpoints (`/archives-v1/cras` et `/statistiques`) ne sont pas importés aujourd'hui (à valider avec l'équipe métier si c'est intentionnel — voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) Q2).

Cet import fonctionne selon une chaîne de validation quotidienne automatisée : sauvegarde d'une copie de test → exécution → vérification automatique → déploiement en production si validé. Pas de planification spécifique côté import Coop — c'est cette chaîne de validation qui déclenche l'exécution.

## Règles métier importantes

### Coordinateurs sont médiateurs

Un coordinateur (personne animant une équipe) est traité comme exerçant aussi l'activité de médiation. C'est une règle appliquée à l'import : si l'API renvoie quelqu'un comme "coordinateur" mais pas "médiateur", on le redéfinit en médiateur pour qu'il soit comptabilisé dans les indicateurs de couverture territoriale. (Raison métier à clarifier : règle voulue ou palliatif technique — voir Q1 en questions-métier.)

### Confidentialité des médiateurs

Si un médiateur a explicitement désactivé sa visibilité sur Coop, ce drapeau est respecté : il n'apparaîtra pas sur la carte publique ni dans l'API publique. Historiquement, ce drapeau était ignoré : 24 835 médiateurs qui demandaient à être cachés restaient affichés. C'est corrigé depuis avril 2026.

### Unification avec les Conseillers Numériques officiels

Beaucoup de structures et de personnes existent dans deux sources : Coop et le registre officiel des Conseillers Numériques. Le dataspace détecte cette coexistence (via un identifiant partagé entre les deux registres pour les personnes — l'identifiant officiel CoNum ; rapprochement par SIRET pour les structures) et les unifie au lieu de créer des doublons. Cela évite les contradictions, permet d'enrichir les données d'une source avec l'autre, et facilite le suivi parcours d'une personne.

### Articulation avec Aidants Connect

Mécanisme similaire : une personne peut être à la fois médiateur Coop et aidant de la plateforme Aidants Connect. Elle n'apparaît qu'une fois en base de données, mais est enrichie des deux contextes.

### Comptage des affectations

Une personne peut avoir plusieurs affectations (lieux où elle exerce, structures qui l'emploient). Ces affectations sont consolidées de toutes les sources, avec la source documentée pour chaque (qui l'a rapporté). Une même personne / structure peut avoir jusqu'à **quatre** affectations distinctes :
- en tant que lieu d'activité Coop,
- en tant qu'emploi via Coop (si la personne n'est pas pleinement identifiée dans le registre Conseillers Numériques),
- en tant qu'emploi via Conseillers Numériques,
- en tant qu'emploi via Aidants Connect.

La règle d'unicité combine quatre critères — la structure, la personne, le type d'affectation, et la source qui l'a remontée — pour éviter les doublons entre sources sur le même type, tout en autorisant plusieurs lignes côte à côte (par exemple une affectation Coop et une affectation Aidants Connect pour la même personne dans la même structure). On obtient ainsi une vue riche du parcours d'une personne à travers les dispositifs.

## Évolutions récentes (avril 2026)

### Problèmes corrigés

- **24 835 médiateurs visibilité ignorée** — Le drapeau "visible/masqué" demandé côté Coop était lu au mauvais endroit, ce qui faisait que tous les médiateurs ayant demandé à être cachés restaient affichés en public. Corrigé.

- **Communes employeuses de médiateurs non-CN perdues** — Le système supposait à tort que les structures employeuses (communes, EPCI) étaient déjà importées par le module Conseillers Numériques. Or ce module n'importe que les structures employant des CN. Résultat : communes-mères des médiateurs non-CN étaient silencieusement perdues, ainsi que leurs affectations. Corrigé. Le dédoublonnage des structures est maintenant insensible à la casse.

- **Typologies de structures corrompues** — Un défaut du traitement des listes (typologies, services, etc.) créait un doublement de mise en forme qui corrompait les données enregistrées. Lors d'une fusion de doublons structure, les typologies corrompues d'une source contaminaient l'autre. Corrigé.

- **Mises à jour sautées entre sources** — L'import Conseillers Numériques bumpe le horodatage de toutes les personnes (même sans modification métier). Coop comparait contre cet horodatage global et pensait à tort que ses données étaient déjà reflétées, sautant les véritables modifications (changement de numéro, etc.). Désormais chaque source compare contre son propre horodatage source.

## Questions ouvertes côté métier

Voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) pour le détail des questions Q1–Q5 spécifiques à Coop :

- **Q1** : Forcer les coordinateurs en médiateurs est-ce une règle métier voulue, ou un bug côté API à corriger ?
- **Q2** : Les données d'archives et statistiques Coop doivent-elles être importées ?
- **Q3** : Le comptage de médiateurs en activité par structure doit-il être mis à jour à chaque rafraîchissement ou immuable ?
- **Q4** : Quand une structure Coop se reconnaît avec une structure déjà importée par Conseillers Numériques, faut-il les unifier ?
- **Q5** : Y a-t-il des champs critiques manquants (formations, frais, accompagnements) à souligner pour la doc ?
- **Q20** : Plusieurs catégories de structures (frais à charge, formations, itinérance, modalités d'accès) sont enregistrées à la première remontée mais jamais rafraîchies ensuite. Voulu ou oubli ?
- **Q21** : Les horaires et modalités de prise de rendez-vous sont enregistrés à la première remontée mais jamais mis à jour ensuite. C'est exactement le type de donnée qui change — voulu ou oubli ?

## Pour aller plus loin

- **Documentation technique** : [`coop.md`](coop.md) — détails SQL, mappages, stratégies de fusion.
- **Questions en cours** : [`questions-metier-en-cours.md`](questions-metier-en-cours.md) — débats ouvert avec l'équipe métier.
- **Historique fonctionnel** : [`../CHANGELOG-metier.md`](../CHANGELOG-metier.md) — changements sur l'ensemble du dataspace.
