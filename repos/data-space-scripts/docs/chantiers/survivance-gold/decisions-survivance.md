# 20 — Tableau de décision : règles de survivance du gold

← [Retour au document central](../../architecture/README.md)

> **Document d'arbitrage métier** — prérequis n°1 de la bascule dbt
> ([fiche 05](../../architecture/transformations-elt-dbt.md#prérequis-avant-le-premier-modèle)).
> Chaque ligne = une règle que le code applique AUJOURD'HUI (constat détaillé et sourcé
> dans la [fiche 18](cartographie-ecritures-gold.md)) + une proposition + une case
> **Décision** à remplir. Une fois arbitré, ce tableau devient la spécification des
> règles de survivance ([fiche 04 §3](../../architecture/mdm-reconciliation.md)) — la doc fait foi, le
> code l'implémente.
>
> **Comment lire** : « qui gagne » = quand deux sources donnent des valeurs différentes
> pour le même champ de la même fiche, laquelle est conservée. Les propositions sont des
> recommandations techniques, PAS des décisions — c'est la colonne Décision qui compte.
>
> Statut : **en attente d'arbitrage** (aucune ligne tranchée à ce jour).

## Les 3 décisions transverses (à trancher en premier)

Elles conditionnent la lecture de tout le reste.

| # | Question | Aujourd'hui | Proposition | Décision |
|---|----------|-------------|-------------|----------|
| T1 | **Quel régime de survivance par défaut ?** | 4 régimes cohabitent selon la table (voir synthèse fiche 18) ; sur structure et personne, c'est l'ordre de passage des imports qui décide — résultat non déterministe | Généraliser le régime de `lieu_inclusion` : **« la modification la plus récente à la source gagne »** (fraîcheur comparée entre sources), le seul régime qui rende le résultat indépendant de l'ordre des runs | ☐ |
| T2 | **Les corrections humaines (MIN) survivent-elles aux imports ?** | Partiellement : protégées sur `lieu_inclusion` (via `updated_at_min`), écrasables ailleurs | **Priorité maximale toujours** : une valeur corrigée par un humain n'est jamais écrasée par un import ; la lever = action humaine explicite | ☐ |
| T3 | **Les fusions automatiques de doublons (mensuel, personnes) continuent-elles sans validation humaine ?** | Fusion automatique au seuil 1.0 chaque 1er du mois, avec suppression physique du doublon | Zone grise → **file de revue humaine dans MIN** (fiche 04 §2) ; l'automatique ne fusionne que les certitudes (identifiant partagé) | ☐ |

## Structure (employeur — `structure_administrative`)

Sources : coop, aidants-connect (AC), idposte. Une même structure peut venir des trois.

| Champ | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| SIRET | Premier qui le pose, définitif (jamais remplacé) | Un SIRET faux posé en premier est indélogeable ; deux sources en désaccord = probable erreur de rapprochement | Premier posé conservé, **conflit détecté → revue humaine** (jamais d'écrasement automatique) | ☐ |
| Nom de l'antenne | Posé à la création, plus jamais réécrit par aucune source (gardes anti-écrasement) | Statu quo issu d'incidents passés — semble voulu | **Valider le statu quo** : le nom appartient à la fiche | ☐ |
| Adresse | Incohérent : coop/AC = premier arrivé ; **idposte écrase toujours** (même une adresse plus fraîche) | Un millésime idposte potentiellement ancien remplace une adresse déclarée récemment | Fraîcheur comparée (T1) + la BAN comme référentiel du format | ☐ |
| Infos INSEE (état, activité, catégorie juridique, dénomination) | Dernier import passé gagne | Les valeurs viennent toutes de l'API SIRENE (caches partagés) → conflit réel faible, sauf millésime périmé | **SIRENE = seule autorité** sur ces champs ; aucune source ne les fournit directement | ☐ |
| Rattachement idposte (pose de l'identifiant) | Rapprochement flou sur le nom (similarité), **sans seuil minimal** : le meilleur score gagne, même très faible ; définitif | Rattachements faux possibles, invisibles, irréversibles | Seuil explicite en configuration ; sous le seuil → revue humaine ; score conservé | ☐ |
| Identifiant coop | Le plus récent gagne (gère la rotation des identifiants côté coop) | Statu quo technique assumé | Valider le statu quo | ☐ |
| Désactivation (structure fermée / disparue) | Seuls AC et MIN désactivent ; une structure disparue de coop ou d'idposte **reste active pour toujours** | Structures fantômes | Définir la règle par source : que signifie « absente du flux » pour coop / idposte ? | ☐ |
| Création silencieusement échouée | Une création idposte en collision est **abandonnée sans trace** | Perte de données invisible (cousin gold des drops silencieux traités en quarantaine) | Toute création échouée → quarantaine avec motif | ☐ |

## Personne (médiateur, aidant, conseiller numérique)

Sources : coop, AC, idposte. Une même personne peut venir des trois (la fiche porte
jusqu'à 4 identifiants source).

| Champ | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| Nom / prénom | coop et AC écrasent chacun quand LEUR flux avance → la valeur **oscille au rythme des imports** | Non déterministe ; à qui appartient l'état civil ? | Fraîcheur comparée (T1), ou désigner une source d'autorité | ☐ |
| Coordonnées (contact) | Fusion clé par clé, le dernier import gagne | Un email périmé peut recouvrir un frais (et inversement) | Fraîcheur comparée par clé (téléphone, email…) | ☐ |
| Visibilité sur la carte publique | coop exclusivement (choix exprimé par la personne) — mais simple convention, aucun garde-fou | Incident passé : 24 835 personnes exposées | **Sanctuariser** : champ à écrivain unique coop, protégé (pas juste une convention) | ☐ |
| « Est médiateur » | idposte le pose à VRAI en écrasement, y compris si coop dit FAUX | Deux sources en désaccord sur un rôle | Définir : le rôle est-il l'union des sources ou la vue de la plus fraîche ? | ☐ |
| Identifiants source (les 4) | Premier posé + garde anti-vol (mais la garde n'existe que côté coop) | Vol d'identifiant théoriquement possible via idposte | Généraliser la garde à tous les écrivains | ☐ |
| Champs propres à AC (formation, profession, nb accompagnements…) | AC seul écrivain | Sain | Valider le statu quo | ☐ |
| Désactivation | coop seul ; **un aidant désactivé côté AC reste une personne active** | Personnes fantômes | Définir la règle : la désactivation AC vaut-elle désactivation de la personne ? | ☐ |
| Fusion de doublons | Automatique mensuelle, seuil 1.0, suppression physique du doublon | Cf. décision T3 | → T3 | ☐ |

## Lieu d'inclusion numérique (`lieu_inclusion`)

Sources : carto (fichier national), coop, MIN. **Régime le plus sain du gold** : la
modification la plus récente à la source gagne, MIN protégé.

| Champ | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| Attributs métier (nom, services, horaires, contact…) | Le plus récemment modifié à la source gagne ; MIN bloque les imports | C'est le modèle candidat de T1 | **Valider comme régime de référence** | ☐ |
| Cycle de vie (visible / retiré de la carte) | carto seul : présent au flux = visible, absent = masqué + lien décroché — **sans date ni motif** | Aucune trace de quand/pourquoi un lieu a disparu | Tracer la date et le motif de désactivation | ☐ |
| Rapprochement coop ↔ carto | Extraction d'identifiant par expression régulière sur l'id composite du fichier national | Fragile : un changement de format côté mednum change le comportement en silence | Test de garde sur le format + alerte au premier id non conforme | ☐ |

## Adresse (référentiel partagé)

| Champ | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| La fiche adresse entière | Append-only : **premier arrivé garde la ligne**. Deux qualités cohabitent sous la même clé : version géocodée BAN (coop/AC) vs parse artisanal du fichier carto | Une adresse « artisanale » peut prendre la place de la version BAN si carto passe en premier | **La BAN est le référentiel** : une version géocodée BAN remplace toujours une version non-BAN ; jamais l'inverse | ☐ |
| Adresses orphelines | Jamais supprimées, accumulation infinie | Bruit croissant | Ménage périodique des adresses non référencées (décision d'exploitation) | ☐ |

## Affectations (personne ↔ structure, personne ↔ lieu)

Une ligne par (personne, cible, **source**) : les sources ne se disputent jamais une
ligne — mais chacune gère « actif / inactif » à sa façon.

| Sujet | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| Cycle de vie | coop désactive les disparus à chaque import ; **AC et idposte ne désactivent jamais** → affectations fantômes | Trois cycles de vie incompatibles | Harmoniser : chaque source désactive ses propres lignes absentes de son flux | ☐ |
| Sémantique « actif » | Différente par source (coop = présent au snapshot ; AC = état de la personne ; idposte = contrat en cours) | Le même mot ne veut pas dire la même chose | Documenter la définition par source dans le dictionnaire de données ; les consommateurs choisissent en connaissance | ☐ |
| Qui fait foi pour un consommateur ? | Aucune règle : « la » vérité = l'union des lignes | Chaque consommateur invente sa préséance | Règle de préséance publiée (ex. idposte fait foi pour les conseillers numériques) | ☐ |

## Coordination (coordinateur ↔ médiateur)

| Sujet | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| Cycle de vie | Une coordination ouverte **ne se ferme jamais** (une fin arrivant plus tard crée une nouvelle ligne à côté ; une disparition du flux ne ferme rien) | Liens périmés éternels | Aligner sur le modèle actif/inactif des affectations | ☐ |

## Postes / contrats (conseillers numériques)

| Sujet | Règle appliquée aujourd'hui | Enjeu | Proposition | Décision |
|-------|-----------------------------|-------|-------------|----------|
| Tout le contenu | **Remplacement intégral à chaque millésime** (tout est vidé puis rechargé, les identifiants internes changent à chaque run) | Tout consommateur qui mémorise un identifiant pointe dans le vide ; l'historique inter-millésimes est perdu | Clés stables via le crosswalk (fiche 04) ; le contrat n'a AUCUNE clé métier aujourd'hui — en définir une | ☐ |

## Accompagnements AC (mensuel)

Rien à arbitrer : écrivain unique, clé métier claire, mise à jour déterministe — c'est
la table de référence du « comment on voudrait que le gold s'écrive ».

## Après l'arbitrage

1. Chaque ligne tranchée est reportée ici (colonne Décision : règle retenue + date).
2. Le tableau validé devient la spécification des modèles de réconciliation dbt
   ([fiche 05](../../architecture/transformations-elt-dbt.md)) — et, en attendant dbt, de tout correctif
   ponctuel sur les écrivains actuels.
3. Les écarts entre décision et code actuel deviennent la liste des chantiers, priorisés
   par le métier.
