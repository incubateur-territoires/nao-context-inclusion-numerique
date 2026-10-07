# Déduplication / fusion des structures — note de décision PO

> Objectif : faire le point pour le PO sur la déduplication des structures
> après la refonte `structure_administrative` / `lieu_inclusion`, et
> identifier ce qu'il reste à trancher côté métier.
>
> Trois parties : **ce qu'on avait avant (et pourquoi)**, **ce qu'on a fait**,
> **ce qui pourrait manquer (décisions à prendre)**.

---

## 1. Ce qu'on avait avant — et pourquoi

### Le problème d'origine

La base agrège des structures venues de **5 sources** : Coop médiation
numérique, Aidants Connect, cartographie nationale, id-poste / CoNum, et
saisie manuelle MIN. Ces sources décrivent souvent **les mêmes entités**,
mais chacune à sa façon → doublons cross-source historiques.

Surtout, une **seule table** mélangeait deux concepts en réalité très
différents :

| Concept | Donnée fiable | Donnée non fiable |
|---|---|---|
| **Entité légale** (employeur, signataire de convention) | le **SIRET** | l'adresse (souvent celle du siège) |
| **Lieu d'inclusion** (lieu physique d'accueil du public) | l'**adresse** | le SIRET (« portage » : une mairie partage son SIRET avec N lieux) |

La cartographie nationale amenait **100 % de lieux d'inclusion** — donc des
données structurellement éloignées d'une entité légale. Les mélanger dans
une seule table rendait la déduplication ingérable.

### Les deux DAGs « similarities »

Pour rattraper les doublons, on faisait tourner deux traitements de
**rapprochement flou** (~1 070 lignes au total) :

- `structures-similarities` : tentait de **fusionner les structures
  considérées comme doublons entre sources**, par SIRET + adueresse.
- `personne-similarities` : idem côté personnes (nom + prénom + commune).

**Point important pour lever une confusion fréquente** : l'objectif de
`structures-similarities` n'a **jamais été** de faire le lien entre une
entité légale et un lieu d'inclusion (cette relation existait déjà,
autrement, via les affectations de personnes typées « emploi » vs
« lieu »). Son but était la **fusion des doublons cross-source**. C'était
même la **motivation principale du split** : on ne peut pas dédupliquer
proprement tant que SIRET-fiable et adresse-fiable cohabitent dans la même
table.

### Limites de cette approche

- Rapprochement **flou** = risque de faux positifs (fusionner à tort).
- Lourd à maintenir, exécuté à chaque run, sans garantie de résultat.
- Aucune contrainte en base n'empêchait un nouveau doublon d'apparaître.

---

## 2. Ce qu'on a fait

### a. Le split + les garanties d'unicité

On a séparé l'entité légale `structure_administrative` (clé = SIRET, ou
SIRET + antenne) des `lieu_inclusion` (lieux physiques). Surtout, des
**contraintes d'unicité** garantissent désormais l'absence de doublon **par
identifiant** : SIRET, RNA, coop_id, ac_id, tp_id, carto_id.

➡️ **Mesure post-refonte : 0 doublon résiduel** sur tous ces axes. La
déduplication par identifiant exact est maintenant **automatique et
garantie par le schéma**, plus par un traitement batch a posteriori.

### b. La notion d'antenne (ajoutée en cours de route)

Un même SIRET peut légitimement porter **plusieurs structures distinctes**
(réseaux type Emmaüs Connect, Groupe SOS…) : le siège signe la convention,
mais les contrats sont portés par les antennes. On a donc ajouté une
**dénomination d'antenne** pour ne PAS écraser ces cas. Aujourd'hui ~5 500
structures sur ~11 300 portent une antenne.

### c. Le lien structure ↔ lieu (table d'association)

On a **gardé la possibilité** de relier une entité légale et un lieu via une
table d'association — sans rétablir la fusion automatique. Son alimentation
aujourd'hui :

| Quand | Mécanisme | Critère | Statut |
|---|---|---|---|
| **Pendant la migration** (one-shot) | les structures « mixtes » de l'ancienne table (à la fois employeuse + lieu) | héritage de l'ancien identifiant commun | figé |
| **Pendant la migration** (rattrapage one-shot) | lieux orphelins | SIRET partagé, 1 seul lien « le plus pertinent » | figé |
| **En continu, aujourd'hui** | **le DAG Coop uniquement** | `coop_id` **partagé** entre l'entité et le lieu | actif à chaque run |

➡️ **La seule liaison créée automatiquement sur les données vivantes
aujourd'hui** est celle des structures Coop mixtes, via leur identifiant
Coop commun. C'est le **seul critère jugé fiable** (on ne marie jamais par
SIRET partagé, à cause du portage).

### d. Les deux DAGs « similarities » dépréciés

Devenus largement obsolètes (la dédup par identifiant est absorbée par les
contraintes). Ils sont désactivés et programmés pour suppression définitive.

### e. Une UI de fusion manuelle (MIN)

Pour les cas résiduels **ambigus** (non détectables par identifiant exact),
une **UI admin de fusion supervisée** a été construite : détection sur
3 signaux + fusion gagnant/perdant **tracée et réversible** (soft-delete +
journal d'audit).

### f. Ce qu'on a volontairement mis de côté

Le **rapprochement / fusion des lieux entre sources** (ex. un lieu carto qui
serait le même qu'un lieu Coop sans identifiant commun) a été laissé de
côté **le temps d'y voir plus clair**. C'est un choix assumé, pas un oubli.

---

## 3. Ce qui pourrait manquer — décisions à prendre

### Les doublons restants ne sont PAS détectables par identifiant

Ce sont des cas **ambigus** : automatiser, c'est risquer de **fusionner à
tort des entités réellement distinctes**. D'où le besoin d'arbitrage métier.
Chiffres réels pour ancrer la décision :

| Cas | Volume | Lecture métier |
|---|---|---|
| Antennes distinctes sous un même SIRET | **2 007 SIRET** | **Légitimes — jamais fusionner** |
| Établissements multiples d'une même entité (même SIREN, SIRET ≠) | majorité des 174 groupes ci-dessous | **Distincts — fusionner changerait le sens (postes, conventions, subventions)** |
| « SIRET + antenne » ambigu (1 ligne sans antenne + 1 avec) | **20 cas** | Candidats nets à la fusion |
| Même nom + même commune, SIRET divergents | **174 groupes** | Surtout des multi-établissements → fusion souvent une erreur |
| RNA partagé entre SIRET différents | **0** | Aucun cas aujourd'hui |
| Lieu ↔ entité via SIRET partagé | **1 462 paires** + **3 193 lieux** avec SIRET sans lien | **SIRET pollué par le portage — ne pas marier automatiquement** |

### Le « trou » fonctionnel à connaître

Un lieu importé par la **cartographie** qui correspond à une entité légale
importée par id-poste ou Aidants Connect, **sans `coop_id` commun**, ne sera
**jamais relié automatiquement** : aucune routine ne le couvre (seul Coop
crée des liens). Ces lieux restent sans entité associée jusqu'à un
traitement manuel. C'est cohérent avec ce qui a été décidé, mais c'est la
limite à expliciter au PO.

### Les 6 décisions à instruire avec le PO

1. **Niveau d'automatisation** : tout-auto / semi-auto (l'algo propose,
   l'humain valide) / détection seule — et **pour quels signaux**.
2. **Seuil de confiance** : à partir de quelle preuve accepte-t-on une
   fusion sans relecture (identifiant exact ? nom + adresse exacte ?
   similarité floue ?).
3. **Faux positif vs faux négatif** : qu'est-ce qui coûte le plus cher —
   **fusionner à tort** (perte/mélange de postes, conventions,
   rattachements MIN) ou **laisser un doublon** (double comptage carto,
   confusion gouvernance) ? Cela oriente l'agressivité de l'algo.
4. **Réversibilité comme condition** : n'autoriser l'auto que si
   soft-delete + journal + annulation possible ? Quel délai de revue ?
5. **Gouvernance** : qui est responsable métier d'une fusion (admin
   national ? gestionnaire territorial ?), et quelles fusions exigent une
   validation humaine obligatoire ?
6. **Périmètre lieux** : automatiser la dédup des lieux (nom + adresse) ou
   la garder 100 % manuelle vu le risque de portage ?

### Politique de fusion proposée (synthèse)

| Signal | Volume | Action recommandée | Validation humaine | Réversible |
|---|---|---|---|---|
| Identifiant exact (SIRET, coop_id, ac_id, RNA, carto_id) | 0 doublon | **Automatique** (contrainte d'unicité) | Non | Sans objet (jamais créé) |
| SIRET + antenne ambigu | 20 | **Semi-auto** : proposé à l'admin | Oui | Oui (UI) |
| Même nom + commune, SIRET ≠ | 174 groupes | **Détection seule** (souvent multi-établissements) | Oui, obligatoire | Oui |
| Antennes distinctes / même SIRET | 2 007 SIRET | **Ne jamais fusionner** | — | — |
| Lieu ↔ entité via SIRET partagé | 1 462 + 3 193 | **Ne pas marier auto** (portage) ; script supervisé | Oui | Oui |
| Lieu ↔ lieu (nom + adresse) cross-source | à mesurer | **Manuel** (UI) tant que non cadré | Oui | Oui |

**Recommandation transverse** : conserver l'automatisme **uniquement** là
où la preuve est un identifiant exact (déjà le cas, garanti par le schéma).
Tout le reste passe par l'UI de fusion supervisée, réversible. C'est le seul
réglage qui protège les 2 007 antennes légitimes et les multi-établissements
contre une fusion destructrice.

---

## Pour mémoire — pointeurs techniques

- Cadrage refonte : [`refonte-structure-plan.md`](refonte-structure-plan.md) (section N5 : dépréciation des DAGs similarities ; N9 : qualité SIRET côté lieux / portage).
- Lien structure ↔ lieu maintenu en continu : `coop-dag.py`, fonction `structures_ingest()` (insertion par `coop_id` partagé, `ON CONFLICT DO NOTHING`).
- Remplissage one-shot de l'association : migrations V075 (mixtes) et V093 (rattrapage SIRET).
- UI de fusion manuelle : branche en cours côté MIN (3 signaux + winner/loser + journal d'audit).
