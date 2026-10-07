# Lieux et médiateurs : comprendre ce qui s'affiche (et ce qui ne s'affiche pas)

*Guide à destination du support — version sans jargon technique.*

> **À quoi sert ce document.** Quand un utilisateur signale « mon lieu n'apparaît
> pas sur la carte », « ce médiateur ne devrait plus être là » ou « ma
> modification n'est pas prise en compte », ce guide explique d'où viennent les
> données, à quel rythme elles circulent, et quelles sont les raisons possibles
> d'une apparition ou d'une disparition. Les questions les plus fréquentes sont
> traitées à la fin, avec une liste de vérifications.
>
> La version technique détaillée (pour les développeurs) est dans
> [`cycle-de-vie-lieux-personnes.md`](cycle-de-vie-lieux-personnes.md).

---

## 1. Le décor : qui parle à qui

Quatre grandes briques manipulent les lieux d'inclusion numérique et les
professionnels (médiateurs, conseillers numériques, aidants) :

- **La Coop numérique** : l'outil de travail quotidien des médiateurs. C'est là
  qu'ils décrivent leurs lieux d'activité et leur profil.
- **La carte nationale** (cartographie de l'inclusion numérique) : le site grand
  public où les lieux et les médiateurs sont affichés.
- **MIN** (Mon Inclusion Numérique) : l'outil des gestionnaires (préfectures,
  collectivités…) pour piloter le déploiement sur leur territoire.
- **L'entrepôt de données** : le socle de données commun, invisible du public,
  où toutes ces informations sont rassemblées. La carte, MIN et les statistiques
  lisent tous dans l'entrepôt.

À cela s'ajoutent deux sources externes qui alimentent l'entrepôt :

- les **données Conseiller numérique** (contrats, postes, employeurs) ;
- les **données Aidants Connect** (aidants habilités et leurs structures).

**L'idée clé** : chaque outil ne « possède » pas ses propres données dans son
coin. Tout converge vers l'entrepôt, et chaque écran (carte, MIN,
statistiques) est une **fenêtre** sur l'entrepôt — chacune avec ses
propres règles d'affichage. C'est pourquoi une même personne peut être visible
dans un outil et pas dans un autre : ce ne sont pas les données qui diffèrent,
ce sont les règles de la fenêtre.

### Quelques ordres de grandeur (septembre 2026)

- **~24 300 lieux** connus de l'entrepôt : ~11 500 viennent du seul fichier
  national, ~7 800 sont connus des deux côtés (Coop + fichier national),
  ~5 000 n'existent que dans la Coop.
- **~18 800 lieux affichés sur la carte.** Les ~5 000 lieux « Coop seulement »
  n'y sont pas : la grande majorité sont **masqués par le choix de leur
  médiateur**, et les autres ne sont pas encore **publiés par la Coop** — la
  Coop ne transmet un lieu à la carte que lorsqu'un médiateur visible y exerce
  et qu'au moins un service y est déclaré (cf. § 4). Et 23 lieux connus du
  fichier national sont volontairement cachés par le choix de leur médiateur.
- **~17 000 personnes** connues de l'entrepôt, dont ~3 800 avec un compte Coop.
  **~2 300 médiateurs sont affichés sur la carte**, répartis sur ~8 300 lieux —
  un peu moins de la moitié des lieux de la carte affichent donc au moins un
  médiateur.

## 2. Première règle d'or : rien n'est jamais vraiment effacé (sauf fusion)

Quand un lieu ou une personne « disparaît » d'un écran, la fiche existe presque
toujours encore dans l'entrepôt. Elle est simplement **marquée**
(supprimée, masquée, inactive…) et la fenêtre concernée choisit de ne plus la
montrer.

**La seule vraie exception : les fusions de doublons.** Quand deux fiches
décrivent le même lieu (ou la même personne) et sont fusionnées, la fiche en
double est **réellement supprimée** — mais pas perdue : tout ce qu'elle portait
(activités, rattachements, informations) a d'abord été reversé dans la fiche
conservée, et l'opération laisse une trace consultable par l'équipe data.

Conséquence pratique pour le support : face à une disparition, la bonne question
n'est pas « où sont passées les données ? » mais « **quelle règle d'affichage la
fiche ne remplit-elle plus ?** ». Et face à une présence indésirable : « quelle
règle continue-t-elle de remplir ? ».

## 3. Deuxième règle d'or : les délais de mise à jour

Toutes les informations ne circulent pas à la même vitesse :

| Ce qui change | Délai pour le voir ailleurs |
|---|---|
| Un médiateur modifie son lieu dans la Coop | **immédiat** dans l'entrepôt ; sur la carte : au prochain rafraîchissement, **jusqu'à ~5 h** |
| Un gestionnaire modifie un lieu dans MIN *(lieux du fichier national uniquement ; les lieux Coop se modifient dans la Coop)* | **immédiat** dans l'entrepôt et MIN ; sur la carte : **jusqu'à ~5 h** |
| Le fichier national des lieux (partenaires hors Coop) | **chaque nuit** |
| Les données Aidants Connect | **chaque matin** |
| Les données Conseiller numérique (contrats, postes) | **toutes les deux semaines** environ |
| Contrôles et rattrapages automatiques | **chaque matin** |

**Cas particulier de la carte nationale** : le site de la carte garde sa propre
copie des données et la recharge par cycles — le délai entre une modification et
son affichage sur la carte peut atteindre **environ 5 heures**, même quand
l'entrepôt est déjà à jour. C'est normal, pas une panne. *(Une amélioration est
à l'étude pour ramener ce délai à quelques minutes.)*

Réflexe support : avant d'ouvrir un signalement, vérifier si le délai normal est
simplement encore en cours. Une modification faite dans la Coop se voit vite
dans les outils, mais la carte peut mettre ~5 h à la refléter ; une fin de
contrat de conseiller numérique peut mettre **jusqu'à deux semaines** à arriver
dans l'entrepôt.

## 4. Les lieux d'inclusion

### D'où viennent-ils ?

Un lieu peut entrer dans l'entrepôt par trois portes :

1. **La Coop** : un médiateur déclare son lieu d'activité. C'est la source la
   plus vivante.
2. **Le fichier national** de la cartographie : des lieux transmis par d'autres
   réseaux et partenaires (France Services, associations, collectivités…),
   rechargé chaque nuit.
3. **MIN** : les gestionnaires corrigent les fiches des lieux venus du fichier
   national (informations, affichage sur la carte, suppression). Les lieux
   déclarés dans la Coop sont **en lecture seule dans MIN** : un message renvoie
   vers la Coop, où le médiateur les gère lui-même. *(Fonction en cours de
   déploiement, réservée aux testeurs pour l'instant.)*

Un même lieu réel peut être connu de plusieurs sources à la fois. Dans ce cas,
un travail de rapprochement (en partie automatique, en partie validé par un
humain) relie les fiches pour n'en montrer qu'une.

### Qui a « raison » quand deux sources disent des choses différentes ?

Quatre principes simples :

- **L'information la plus récente gagne** — à condition que la date de mise à
  jour corresponde à un vrai changement.
- **Celui qui sait a raison** : une information renseignée ne se fait jamais
  écraser par un « vide ». Si une source ne connaît pas le téléphone d'un lieu,
  elle ne peut pas effacer le téléphone connu par une autre.
  *Pourquoi cette règle ?* Elle protège contre les **flux automatiques** : un
  fichier importé chaque nuit avec une colonne vide effacerait sinon des
  milliers de téléphones d'un coup. Elle ne s'applique qu'aux automates : un
  **humain** qui efface volontairement une information est respecté (il retire
  sa contribution), et si une valeur venue d'ailleurs subsiste, l'écran de
  comparaison la lui re-propose pour qu'il tranche. Le revers assumé : une
  vieille valeur fausse venue d'une autre source peut persister jusqu'à ce
  qu'un humain la corrige — c'est le prix pour ne jamais perdre de donnée en
  silence.
- **En cas de vrai désaccord, c'est un humain qui tranche** : quand la fiche
  Coop et la fiche de l'entrepôt divergent, le médiateur qui veut modifier
  son lieu voit d'abord un écran de comparaison et choisit quoi garder. Rien
  n'est arbitré en douce dans son dos.
- **Ce qu'on sait d'un lieu n'est pas ce qu'on a décidé pour lui.** Ce qu'on
  sait (adresse, horaires, services, téléphone…) suit les règles ci-dessus :
  l'information la plus récente l'emporte, et aucune source n'a le dernier mot
  par principe — ni le fichier national, ni la Coop, ni MIN. Ce qu'on a décidé
  (le lieu est-il affiché sur la carte ? est-il supprimé ?) n'appartient qu'aux
  personnes qui gèrent le lieu, depuis la Coop ou depuis MIN. Le fichier
  national est un flux automatique : il ne peut ni masquer ni ré-afficher un
  lieu qu'un humain a géré. Un lieu masqué ou supprimé par un gestionnaire
  reste masqué, même si le fichier national continue de le lister chaque nuit.

### Pourquoi un lieu s'affiche — ou pas — sur la carte

Pour apparaître sur la carte nationale, un lieu doit remplir **trois conditions** :

1. être **référencé** pour la cartographie (il a été rapproché du fichier
   national, automatiquement ou via la file de validation) ;
2. être **marqué comme visible** — pour un lieu de la Coop, c'est le choix fait
   par le médiateur dans la Coop qui commande ;
3. ne pas avoir été **supprimé** par son médiateur.

Pour un lieu de la Coop, le référencement passe par la **publication par la
Coop** : elle ne transmet au fichier national qu'un lieu visible où **au moins
un médiateur visible exerce encore** et qui **déclare au moins un service**. Un
lieu sans médiateur reste dans la Coop, pas sur la carte.

Points importants :

- Un lieu **masqué** par son médiateur (Coop) ou par un gestionnaire (MIN)
  garde sa fiche et son référencement : rendu à nouveau visible, il revient
  tel quel.
- Le fichier national ne peut **ni faire disparaître ni faire réapparaître** un
  lieu géré dans la Coop ou dans MIN : pour ces lieux, seuls ces outils
  commandent.
- Cas connu (en cours de correction) : une petite série de lieux masqués
  apparaît encore dans les fichiers en données ouvertes (data.gouv), alors
  qu'ils sont bien absents de la carte.

## 5. Les personnes (médiateurs, conseillers numériques, aidants)

### D'où viennent-elles ?

Une même personne peut être connue par plusieurs canaux, qui se complètent :

- **la Coop** : son compte et son profil de médiateur ;
- **le dispositif Conseiller numérique** : son poste, son contrat, son employeur ;
- **Aidants Connect** : son habilitation d'aidant et sa structure.

L'entrepôt **rapproche** ces canaux pour reconstituer une seule fiche par
personne (par exemple, reconnaître que tel conseiller numérique et tel compte
Coop sont la même personne). Ce rapprochement est prudent : en cas de doute, on
ne fusionne pas.

### La notion d'« activité » : trois compteurs qui ne disent pas la même chose

C'est la principale source de confusion. Trois choses différentes coexistent :

1. **Avoir un emploi actif** chez une structure (selon la source : contrat
   Conseiller numérique en cours, habilitation Aidants Connect active, ou
   rattachement déclaré dans la Coop) ;
2. **Exercer dans un lieu** : la personne s'est déclarée en activité sur ce lieu
   dans la Coop, sans date de fin ;
3. **Avoir un contrat Conseiller numérique en cours** (non rompu).

Ces trois informations ne se mettent pas à jour automatiquement l'une l'autre.
Exemple concret et fréquent : **un conseiller numérique dont le contrat est
rompu peut rester affiché comme actif** tant que ni lui ni sa structure n'a mis
à jour sa situation dans la Coop. C'est un manque connu (environ 230 cas
identifiés en septembre 2026), pas un bug ponctuel.

### Pourquoi une personne s'affiche — ou pas — sur la carte

Pour qu'un médiateur apparaisse sur la carte, **quatre conditions** doivent
être réunies **en même temps** :

1. il exerce actuellement dans **au moins un lieu** déclaré dans la Coop (et ce
   lieu est lui-même visible, cf. § 4) ;
2. son **compte Coop existe** toujours (non supprimé) ;
3. il n'a pas choisi d'être **masqué** (option de confidentialité dans la Coop) ;
4. sa situation d'emploi l'y autorise (un conseiller numérique doit avoir un
   emploi actif ; un aidant Aidants Connect est admis d'office ; un médiateur
   « autre » est admis sur sa seule déclaration).

⚠️ Ce qui **ne compte pas** : le fait qu'une fiche porte une marque de
suppression dans l'entrepôt. Cette marque est posée par **une seule source** —
Aidants Connect le fait quand une habilitation est retirée — et n'est jamais
effacée si la personne continue d'exercer par ailleurs. Une conseillère
numérique en poste peut donc porter une marque de suppression datant de 2022 :
elle reste, à juste titre, sur la carte. Un essai d'ajout de cette condition le
22/09/2026 a été annulé le jour même, après avoir constaté que les 154 personnes
qu'il retirait étaient toutes en poste.

Autrement dit : **la carte n'affiche que des personnes ayant un compte Coop.**
C'est structurel : la carte affiche les médiateurs *via* leurs lieux d'activité
déclarés dans la Coop, il n'y a pas d'autre chemin. Une personne sans compte
Coop — même conseiller numérique en poste ou aidant habilité Aidants Connect —
n'apparaît jamais sur la carte.

À l'inverse, dans **MIN**, les gestionnaires voient les professionnels de leur
territoire dès qu'ils ont un **emploi actif** connu (Coop, Conseiller numérique
ou Aidants Connect) — pas besoin de lieu. Un filtre « anciens » permet d'y
retrouver les sortants. C'est pourquoi il est normal de voir dans MIN des
personnes absentes de la carte, et réciproquement.

### Pourquoi une personne « disparue » traîne encore quelque part

- **Personne ne supprime les fiches** : si quelqu'un quitte le dispositif, sa
  fiche reste, marquée inactive au mieux. Si la source d'origine (export
  Conseiller numérique, Aidants Connect) cesse simplement de la mentionner, la
  fiche reste **en l'état, sans être désactivée** — sa disparition amont est
  silencieuse.
- Les **tableaux statistiques internes** (Metabase) montrent volontairement tout
  l'historique, y compris les personnes parties ou supprimées : c'est un outil
  d'analyse, pas un annuaire. Ne pas s'alarmer d'y trouver des fiches qui
  n'apparaissent nulle part ailleurs.

### Les coordonnées (nom, email, téléphone) : qui voit quoi, et d'où ça vient

Les coordonnées d'une personne peuvent venir de plusieurs endroits : son
**compte Coop** (la source vivante — c'est elle qui fait foi), et son **dossier
Conseiller numérique** (mails pro et perso déclarés à l'époque du recrutement).

- **Sur la carte nationale** : si le médiateur est visible (cf. plus haut), sa
  fiche affiche son nom et ses coordonnées **lues en direct sur son compte
  Coop** (à défaut, celles du dossier Conseiller numérique). Conséquence : pour
  corriger un email ou un téléphone affiché sur la carte, il suffit de
  **modifier son compte Coop** — le changement apparaît au prochain
  rafraîchissement de la carte (~5 h). Et une personne masquée n'a **aucune**
  coordonnée exposée.

  Depuis septembre 2026, seules les **adresses professionnelles** entrent dans
  ce calcul : l'adresse personnelle déclarée à l'époque du recrutement n'est
  plus utilisée pour alimenter la carte. Attention toutefois : si la même
  adresse a été saisie **aussi** comme adresse du compte Coop, c'est cette
  dernière qui s'affiche — la règle porte sur la provenance de l'adresse, pas
  sur son contenu. Une personne qui ne veut pas voir telle adresse publiée doit
  la changer sur son compte Coop.
- **Dans MIN** : les gestionnaires (accès restreint) voient davantage —
  notamment les mails du dossier Conseiller numérique. ⚠️ Une partie de ces
  coordonnées provient de **copies plus anciennes** : il est possible qu'un
  email soit périmé dans MIN alors que la carte affiche le bon. Dans ce cas, ce
  n'est pas la personne qui s'est trompée — le signaler à l'équipe data.
- **Dans les statistiques internes** (Metabase) : réservées à l'interne, avec
  des versions anonymisées pour les accès larges.
- **En données ouvertes (data.gouv)** : **jamais aucune coordonnée
  personnelle**. Seuls les contacts *des lieux* (téléphone d'accueil, email de
  la structure, site web) sont publiés — ce sont des données professionnelles
  publiques, à ne pas confondre avec celles des personnes.

## 6. Les questions fréquentes, avec la liste de vérifications

### Réflexe n° 0, avant toute vérification : qui gère ce lieu ?

Le premier tri à faire est toujours : **le lieu est-il géré par la Coop, ou
vient-il du fichier national ?** Les règles (et les solutions) diffèrent.

- **Où regarder** : sur la fiche du lieu (carte), le champ « source ».
  « Coop numérique » = géré par la Coop. La présence de médiateurs rattachés
  sur la fiche est aussi un bon indice « Coop ».
- ⚠️ **Limite à connaître** : la « source » affichée est celle du **dernier
  outil qui a écrit** sur la fiche, pas de son origine. Un lieu géré par la
  Coop mais jamais ré-édité récemment peut encore afficher une autre source.
  En cas de doute, l'équipe data tranche en quelques secondes.
- **Qui peut éditer quoi** :
  - lieu **géré par la Coop** → son médiateur, dans la Coop. Dans MIN, il est
    en lecture seule (un message le dit) ;
  - lieu du **fichier national** (sans médiateur Coop) → les gestionnaires,
    dans MIN (fonction réservée aux testeurs pour l'instant) ; sinon il ne
    bouge qu'avec le rechargement nocturne du fichier national. Et si un
    médiateur de la Coop déclare son activité sur ce lieu, la Coop l'« adopte »
    et il devient un lieu géré par la Coop.

### « Mon lieu n'apparaît pas sur la carte »

🎥 Tuto vidéo : [mettre à jour les informations et la visibilité de mon lieu](https://www.loom.com/share/4dc29c9ffd0d40dab4558b4670fed3c8)

1. **Qui gère le lieu ?** (réflexe n° 0 ci-dessus — s'il vient du fichier
   national, les points suivants ne s'appliquent pas)
2. Le lieu est-il **visible** dans les réglages de la Coop ? (choix du médiateur)
3. Le lieu est-il **référencé** pour la cartographie ? S'il vient d'être créé,
   le rapprochement peut être en attente de validation.
4. Le lieu a-t-il été **supprimé** puis recréé récemment ?
5. Le lieu a-t-il été **masqué ou supprimé dans MIN** par un gestionnaire ?
   (le fichier national ne le rallume plus : c'est voulu, cf. § 4)
6. La modification date-t-elle de **moins de ~5 heures** ? (cycle de
   rafraîchissement de la carte, cf. § 3 — délai normal)

### « Ce médiateur ne devrait plus apparaître sur la carte »

1. A-t-il encore une **activité en cours sur un lieu** dans la Coop ? (c'est le
   cas le plus fréquent : la structure n'a pas clôturé son rattachement)
2. S'il s'agit d'un conseiller numérique en fin de contrat : la fin de contrat
   met **jusqu'à deux semaines** à arriver, et ne suffit pas si son rattachement
   Coop reste ouvert (manque connu, cf. § 5).
3. La personne peut se **masquer elle-même** dans la Coop (option de
   confidentialité) : c'est la solution immédiate à proposer.

### « Cette personne n'apparaît pas sur la carte alors qu'elle est en poste »

1. A-t-elle un **compte Coop** avec un **lieu d'activité déclaré** ? Sans cela,
   elle ne peut pas apparaître, quel que soit son statut.
2. Son lieu est-il lui-même visible sur la carte ?
3. A-t-elle activé l'option « ne pas être visible » ?
4. Conseiller numérique : son emploi actif est-il bien connu ? (délai de
   deux semaines possible)

### « Les chiffres de MIN et la carte ne disent pas la même chose »

C'est attendu : MIN compte les professionnels **en emploi** sur un territoire,
la carte affiche les médiateurs **présents dans un lieu visible**. Les deux
règles sont différentes par construction (cf. § 5).

### « Mes coordonnées affichées sont fausses / je veux les changer »

🎥 Tuto vidéo : [modifier mon numéro de téléphone sur la cartographie](https://www.loom.com/share/b7a257c6e17742a9882c7dacdd88cb7d)

1. Sur la **carte** : corriger l'email/le téléphone du **compte Coop** — c'est
   la source affichée ; effet sous ~5 h. En pratique la modification passe par
   **ProConnect** (profil Coop → modifier → continuer vers ProConnect, cf.
   tuto).
2. La personne ne veut plus afficher ses coordonnées du tout : option de
   confidentialité dans la Coop (elle disparaît alors entièrement de la carte).
3. Coordonnées fausses **dans MIN** uniquement : probablement une copie
   ancienne (cf. § 5) — transmettre à l'équipe data.

### « J'ai modifié une fiche et je ne vois pas le changement »

1. Où a été faite la modification (Coop, MIN) et où regarde-t-on le résultat ?
2. Les modifications Coop et MIN sont quasi immédiates dans les outils, mais la
   **carte** peut mettre **~5 h** à les refléter ; ce qui vient des fichiers
   externes suit les délais du § 3.
3. Si deux sources se contredisent, se rappeler : le plus récent gagne, et une
   valeur renseignée ne peut pas être effacée par un vide venu d'ailleurs.

---

*Document rédigé en septembre 2026. En cas de doute sur un cas précis qui ne
rentre dans aucune de ces cases, le transmettre à l'équipe data avec le nom du
lieu ou de la personne et l'écran concerné : des outils internes permettent de
retracer exactement quelle règle s'applique (y compris le motif précis
d'exclusion de la carte).*
