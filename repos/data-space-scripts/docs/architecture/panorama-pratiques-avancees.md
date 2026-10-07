# 14 — Panorama des pratiques avancées : ce qu'on n'adopte pas (encore), et pourquoi

← [Retour au document central](README.md)

## Objet de cette fiche

Les fiches 01 à 13 couvrent les pratiques à mettre en place. Celle-ci complète le panorama
avec **le reste de l'état de l'art** : les pratiques connues, évaluées, et volontairement
non retenues *à ce stade*. Chaque entrée donne le concept, la valeur qu'elle apporterait,
la raison de ne pas l'adopter aujourd'hui, et surtout le **signal de bascule** — le fait
observable qui devrait rouvrir la discussion.

But : qu'aucune proposition future ne soit "une idée nouvelle" — tout est ici, évalué,
avec des critères de décision explicites. Si quelqu'un propose l'une de ces pratiques, la
conversation commence par "le signal de bascule est-il atteint ?", pas par zéro.

---

## 1. Streaming et temps réel (Kafka, CDC, event-driven)

**Concept.** Traiter les données en flux continu plutôt qu'en batch : chaque changement
dans une source est un événement propagé en secondes. Deux variantes : le streaming
d'événements (Kafka, RabbitMQ) et le **CDC** (Change Data Capture — Debezium lit le WAL
PostgreSQL de la source et émet chaque INSERT/UPDATE/DELETE).

**Valeur.** Fraîcheur en secondes au lieu d'heures ; découplage producteurs/consommateurs ;
le CDC capture *tous* les états intermédiaires (un enregistrement modifié 3 fois entre
deux extracts batch ne montre que le dernier état en batch, les 3 en CDC).

**Pourquoi pas ici.** Les usages (cartographie, dashboards, gestion MIN) tolèrent une
fraîcheur quotidienne ; aucune source ne propose de flux d'événements (on consomme des
APIs REST) ; le coût opérationnel d'un cluster Kafka est sans commune mesure avec l'équipe.
La couche bronze horodatée (fiche 01) donne une part du bénéfice CDC (historique des états
vus) à fréquence batch.

**Signal de bascule.** Un consommateur avec un besoin réel < 1 h (ex. affichage temps réel
de disponibilité) ; ou une source qui propose des webhooks/flux — auquel cas commencer par
du **micro-batch** (DAG toutes les 15 min), qui couvre 90 % des "besoins temps réel"
exprimés sans nouvelle infrastructure.

---

## 2. Data lake / lakehouse (S3, Parquet, Iceberg/Delta, Spark)

**Concept.** Stocker les données en fichiers ouverts (Parquet) sur object storage, avec
une couche transactionnelle (Iceberg, Delta Lake) et des moteurs de calcul découplés
(Spark, Trino). Le "lakehouse" fusionne lac (flexibilité, coût) et entrepôt (ACID, SQL).

**Valeur.** Scalabilité quasi illimitée, coût de stockage minimal, séparation
stockage/calcul, formats ouverts pérennes.

**Pourquoi pas ici.** Les volumes (10⁴–10⁶ lignes) tiennent avec aisance dans un
PostgreSQL modeste, transactionnel, avec PostGIS — que l'équipe maîtrise. Un lakehouse
ajouterait trois technologies à opérer pour résoudre un problème (l'échelle) qu'on n'a pas.

**Signal de bascule.** Tables > 10⁸ lignes qui dégradent les runs malgré l'optimisation ;
ou un besoin d'archivage massif du bronze où l'**export Parquet vers object storage**
(sans lakehouse complet) serait le premier pas naturel — cf. rétention, fiche 01.

---

## 3. Semantic layer / metrics store (dbt Semantic Layer, Cube)

**Concept.** Définir les métriques métier ("nombre de structures actives", "taux de
couverture") **une seule fois**, dans une couche déclarative, que tous les outils (BI,
API, notebooks) consomment — au lieu que chaque dashboard recode sa formule.

**Valeur.** Fin des chiffres divergents entre dashboards ; les définitions de métriques
deviennent versionnées et testées comme du code.

**Pourquoi pas ici (pas encore).** L'outillage est jeune et l'échelle du besoin est
modeste. Le problème visé (chiffres incohérents) est d'abord traité par le **modèle
dimensionnel partagé** (fiche 10) et le dictionnaire (fiche 07) : des dimensions communes
et des définitions écrites éliminent l'essentiel des divergences.

**Signal de bascule.** Des définitions de métriques contestées de façon récurrente malgré
le modèle dimensionnel ; ou plus de ~3 consommateurs différents (Metabase + API + rapports)
recalculant les mêmes indicateurs. Premier pas léger : un fichier `metriques.md` normatif
(définition + SQL de référence par indicateur) — un semantic layer en markdown, qui capture
80 % de la valeur.

---

## 4. Data mesh (organisation décentralisée par domaines)

**Concept.** (Dehghani) Décentraliser la data : chaque domaine métier possède et publie
ses données comme des produits, sur une plateforme self-service, avec une gouvernance
fédérée. Réponse aux goulots des équipes data centrales dans les grandes organisations.

**Valeur.** À grande échelle : responsabilisation des domaines, suppression du goulot
central.

**Pourquoi pas ici.** Le data mesh résout un problème d'*organisation* (dizaines d'équipes,
centaines de sources) que ce projet n'a pas — une seule équipe, un seul domaine. L'adopter
serait du cargo cult.

**Ce qu'on en retient quand même** (déjà intégré aux fiches) : le principe **"data as a
product"** (fiche 12) et l'ownership explicite (fiche 07) — les deux idées du mesh qui
valent à toute échelle.

**Signal de bascule.** N/A à l'échelle d'un produit. Si l'écosystème inclusion numérique
inter-SE se structure en domaines publiant leurs données standardisées (data-inclusion en
est le germe), c'est un mesh *inter-organisations* — et les fiches 02/12 en sont exactement
les briques.

---

## 5. Catalogues d'entreprise (DataHub, OpenMetadata, Amundsen)

**Concept.** Plateforme centralisant métadonnées, lineage, ownership, glossaire, avec
recherche et UI — le "Google interne des données".

**Valeur.** Découvrabilité à l'échelle de centaines de tables et dizaines d'équipes.

**Pourquoi pas ici.** Une plateforme à déployer, opérer et alimenter pour un périmètre
(< 100 tables, une équipe) où `COMMENT ON` + dbt docs + ce dossier donnent la même
information sans infrastructure (fiche 07). Le catalogue-outil sans discipline de contenu
est une coquille vide ; la discipline de contenu sans l'outil garde toute sa valeur.

**Signal de bascule.** Plusieurs équipes consommatrices internes qui ne trouvent pas les
données ; ou mutualisation d'un catalogue au niveau d'un écosystème (ANCT/beta.gouv) —
auquel cas y publier nos métadonnées déjà structurées sera trivial.

---

## 6. MLOps, feature stores, et IA sur les données

**Concept.** Industrialisation du machine learning : versionnement des jeux
d'entraînement, feature store (features partagées et servies en ligne/hors ligne),
registre de modèles, monitoring de dérive. Et plus récemment : LLM sur données internes
(RAG, text-to-SQL).

**Valeur potentielle ici.** Le cas d'usage ML le plus plausible existe déjà en germe : le
**matching probabiliste** (fiche 04). Un modèle entraîné sur les décisions humaines de la
file de revue MIN (accepter/rejeter) améliorerait les seuils — c'est exactement ce que
fait Splink (approche Fellegi-Sunter, semi-supervisée).

**Pourquoi pas maintenant.** Pas de corpus de décisions humaines encore (la file de revue
n'existe pas) ; le matching déterministe + fuzzy à seuils couvre le besoin. Le MLOps
outillé (MLflow, feature store) ne se justifie qu'avec des modèles en production.

**Signal de bascule.** Quelques milliers de décisions humaines accumulées dans la file de
revue → entraîner/calibrer Splink devient rentable et **les données d'entraînement
existent grâce au MDM bien conçu** — c'est l'enchaînement vertueux à avoir en tête dès la
conception de la fiche 04 (conserver chaque décision avec ses features). Pour le
text-to-SQL/RAG interne : attendre la maturité, le dictionnaire (fiche 07) en serait le
prérequis de toute façon.

---

## 7. Reverse ETL / activation des données

**Concept.** Renvoyer les données consolidées de l'entrepôt **vers** les outils
opérationnels (CRM, outils de campagne, applications métier) — l'entrepôt comme source
des systèmes d'action.

**Valeur.** Les données réconciliées servent l'action, pas seulement l'observation.

**Pertinence ici — réelle et déjà latente.** MIN *est* un outil opérationnel branché sur
l'entrepôt ; et si demain il faut alimenter d'autres SE ou outils (ex. pousser les
structures consolidées vers un outil de coordination), c'est du reverse ETL. La bonne
réponse actuelle est l'API (fiche 12) en mode pull ; un mode push (DAG qui écrit chez le
partenaire) n'est qu'une variante d'orchestration — pas besoin d'outil dédié (Census,
Hightouch) à cette échelle.

**Signal de bascule.** Plus de 2-3 destinations push avec mapping de champs complexe.

---

## 8. Orchestrateurs alternatifs (Dagster, Prefect) et moteurs embarqués (DuckDB, Polars)

**Concept.** Dagster repense l'orchestration autour des *assets* de données (le graphe
des tables, pas des tâches) avec types, tests et lineage natifs — philosophiquement aligné
avec tout ce dossier. DuckDB/Polars offrent du SQL/dataframe analytique in-process très
rapide, remplaçant pandas dans les pipelines.

**Pourquoi pas ici.** Airflow 3 est en place, maîtrisé, outillé (CI, notifications,
skills) ; migrer d'orchestrateur est un chantier massif pour un gain philosophique que
**dbt + Cosmos apportent déjà en partie** (le graphe d'assets, c'est le DAG dbt). DuckDB :
notre moteur analytique est PostgreSQL — ajouter un second moteur fragmenterait ; l'ELT
(fiche 05) répond au problème pandas autrement.

**Signal de bascule.** Refonte majeure imposée par ailleurs (fin de vie, migration
d'infra) — réévaluer Dagster à ce moment-là, pas avant. DuckDB : éventuel outil ponctuel
d'analyse locale de fichiers sources (lecture Parquet/CSV rapide), sans statut
d'architecture.

---

## 9. Fédération et virtualisation de données (Trino, FDW)

**Concept.** Requêter plusieurs systèmes sources *sans* déplacer les données (moteurs
fédérés type Trino/Presto ; en PostgreSQL : les **Foreign Data Wrappers**).

**Valeur.** Éviter la réplication quand on a juste besoin de joindre ponctuellement.

**Pourquoi pas comme architecture.** La fédération donne de la fraîcheur mais sacrifie
exactement ce que ce dossier construit : l'historisation (bronze), la qualité contrôlée,
l'indépendance aux pannes des sources. Pour un pipeline de *consolidation*, la copie
gouvernée est le bon choix.

**Usage ponctuel légitime.** `postgres_fdw` peut servir pour des vérifications ad hoc
contre une base partenaire accessible — outil de diagnostic, pas d'architecture.

---

## 10. Privacy-enhancing technologies (anonymisation différentielle, synthèse de données)

**Concept.** Au-delà de la pseudonymisation : **k-anonymat** et **confidentialité
différentielle** (garanties mathématiques contre la ré-identification dans les données
agrégées publiées), **données synthétiques** (jeux artificiels statistiquement fidèles
pour le dev et l'open data).

**Pertinence ici.** Réelle dès que l'open data (fiche 12) se concrétise : publier des
agrégats fins (croisements par commune × type × période) peut ré-identifier des individus
dans les petites mailles — le **secret statistique** (règle INSEE : pas de case < k
individus) est le premier garde-fou, simple et normé.

**Signal de bascule.** Publication open data d'agrégats fins → appliquer le secret
statistique d'emblée (peu coûteux) ; données synthétiques si le jeu de dev pseudonymisé
s'avère encore trop identifiant (les personnes d'un petit territoire restent devinables
par leurs attributs).

---

## Synthèse : la grille de lecture

| Pratique | Verdict | Premier pas léger si le besoin émerge |
|----------|---------|----------------------------------------|
| Streaming / CDC | Non — batch suffit | Micro-batch 15 min |
| Lakehouse | Non — PostgreSQL suffit | Export Parquet du bronze pour archivage |
| Semantic layer | Pas encore | `metriques.md` normatif (définitions + SQL de référence) |
| Data mesh | Non-sens à cette échelle | Ses 2 bonnes idées sont déjà dans les fiches 07/12 |
| Catalogue d'entreprise | Non — COMMENT ON + dbt docs | Publier nos métadonnées si un catalogue mutualisé émerge |
| MLOps / ML matching | Pas encore | Concevoir la file de revue (fiche 04) pour conserver les décisions = futur jeu d'entraînement |
| Reverse ETL | Couvert par l'API | DAG push si > 2-3 destinations |
| Dagster / DuckDB | Non — Airflow + PostgreSQL en place | Réévaluer lors d'une refonte imposée |
| Fédération / FDW | Pas comme architecture | `postgres_fdw` en diagnostic ponctuel |
| Privacy avancée | Dès l'open data | Secret statistique (règle des k) sur les agrégats publiés |

La cohérence d'ensemble : **chaque "non" est un "pas tant que le signal n'est pas là", et
chaque signal a un premier pas léger** — la maturité data ne consiste pas à tout adopter,
mais à savoir précisément pourquoi on n'adopte pas, et quand ça changera.

## Références

- Dehghani — *Data Mesh* ; Reis & Housley — *Fundamentals of Data Engineering* (le
  panorama de référence du métier, recommandé comme lecture d'équipe)
- Splink (MoJ) — record linkage probabiliste ; Debezium — CDC
- INSEE — règles du secret statistique ; CNIL — anonymisation vs pseudonymisation
