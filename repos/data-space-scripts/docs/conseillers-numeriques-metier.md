# Conseillers Numériques — vue métier

> Version non-technique de [`conseillers-numeriques.md`](conseillers-numeriques.md). Pour les détails d'implémentation (requêtes SQL, structures de tables, fonctions Python), voir la documentation technique.

## En quelques mots

Le dispositif **Conseillers Numériques France Services** est un programme d'État qui finance des postes de conseillers pour accompagner les citoyens dans leurs démarches numériques. Ces conseillers sont employés par différentes structures (mairies, associations, organismes culturels, etc.). Le dataspace ramène les données du **tableau de pilotage CoNum** maintenu côté ANCT/État (les acronymes internes PMU et PNM désignent les outils de gestion de ce tableau), les transforme en postes, personnes, structures, contrats, formations et subventions, puis les fusionne avec les données des autres sources (Coop, Aidants Connect, Cartographie nationale) pour une vue consolidée.

## Quelles données ramenées ?

Pour chaque poste de conseiller numérique :

- **Postes** — un poste = une unité de financement (un emploi de conseiller numérique). Pour chaque poste : identifiant unique, structure employeur, statut, type de contrat.
- **Personnes** — les conseillers numériques affectés à ces postes. Pour chaque : nom, prénom, et identifiants (dont un identifiant partagé avec le registre officiel CoNum).
- **Structures** — les organismes qui emploient les conseillers numériques. Pour chaque : SIRET, nom, adresse, données administratives (extraites de la base SIRENE).
- **Contrats** — les contrats individuels liant un conseiller à une structure (type, dates de début, date de rupture le cas échéant).
- **Formations** — parcours de formation suivis (type, lieu, dates).
- **Subventions** — financements publics attribués aux postes (deux enveloppes : lancement initial DGCL 2021-2023 et renouvellement DITP/DGE 2023-2025, avec bonifications pour les territoires prioritaires). Voir doc dédiée.

## D'où viennent les données ?

Le dataspace récupère un fichier CSV de pilotage maintenu par l'équipe en charge du dispositif côté ANCT/État. Ce fichier (déposé sur S3, avec une copie locale pour le développement) contient une ligne par conseiller numérique affecté. La synchronisation est **automatisée toutes les 2 semaines** via une chaîne de validation automatisée.

## Règles métier importantes

### Tous les conseillers numériques sont médiateurs

Un conseiller numérique est par définition un agent qui accompagne les usagers en personne. Tous les conseillers importés sont systématiquement marqués comme « médiateurs ». Pas de notion de coordinateur côté CoNum (contrairement à Coop qui distingue les deux rôles).

### Affectations actives ou inactives selon les contrats

Une affectation (lien conseiller ↔ structure) est **active** s'il existe au moins un contrat actif entre eux. Un contrat est actif s'il n'a pas encore été rompu (pas de date de rupture enregistrée). Quand un conseiller part ou change de poste, son affectation devient automatiquement inactive au prochain rafraîchissement des données.

### Unification cross-source des structures

Une même structure peut être remontée par plusieurs sources : registre CoNum, Coop, Aidants Connect, ou Cartographie. Le dataspace détecte ces doublons (rapprochement par SIRET + nom + adresse) et les unifie dans une seule ligne, enrichie par chaque source.

### Agrégation des subventions par poste

Les subventions sont agrégées par poste, pas par conseiller. Un poste avec plusieurs conseillers cumule les montants. Pour les bonifications (territoires prioritaires), on prend la valeur maximale (tous les conseillers d'un même poste ont droit à la même bonification — il ne faut pas les cumuler).

## Évolutions récentes (avril 2026)

Pas de fix isolé spécifique au module Conseillers Numériques en avril 2026. Les évolutions du sous-système subventions sont documentées à part dans [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md).

## Sous-système subventions — Financement de l'État

Le dispositif bénéficie de deux enveloppes distinctes :

- **Enveloppe V1 (DGCL, 2021-2023)** — lancement initial. 50 000 € par poste, sans bonification.
- **Enveloppe V2 (DITP + DGE, 2023-2025)** — renouvellement et pérennisation. 50 000 € par poste + bonification pour les territoires prioritaires (+7 500 € pour un quartier prioritaire, ou +10 125 € pour un quartier prioritaire renforcé).

Les détails (calculs, cas limites, historique des corrections) sont dans [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md).

## Questions ouvertes côté métier

- **Q6** — Comportement de réinitialisation des historiques côté DAGs de réconciliation (qui nettoient les doublons entre structures et personnes) à chaque cycle. Voulu, ou copié d'un autre DAG sans intention claire ?

Voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) pour le contexte complet.

## Pour aller plus loin

- Documentation technique : [`conseillers-numeriques.md`](conseillers-numeriques.md)
- Sous-système subventions : [`subventions-conseiller-numerique.md`](subventions-conseiller-numerique.md)
- Questions métier en cours : [`questions-metier-en-cours.md`](questions-metier-en-cours.md)
- Historique global : [`../CHANGELOG-metier.md`](../CHANGELOG-metier.md)
