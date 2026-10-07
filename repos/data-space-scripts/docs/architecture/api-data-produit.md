# 12 — Produire des données pour des tiers : l'API comme produit

← [Retour au document central](README.md)

## Le concept

La fiche 02 traite des contrats que nous *subissons* (nos sources). Cette fiche est le
miroir : **nous sommes nous-mêmes une source de données** pour des partenaires (API
PostgREST, data.gouv potentiellement, autres SE beta.gouv, dashboards publics). Tout ce
qu'on reproche aux sources amont — drift silencieux, champs non documentés, changements
non annoncés — nous pouvons le faire subir à nos consommateurs.

L'état de l'art s'appelle **"data as a product"** : traiter les données exposées avec les
standards d'un produit logiciel :

| Pratique | Question traitée |
|----------|------------------|
| **Contrat de sortie publié** | Que garantissons-nous ? (schéma, sémantique, fraîcheur, disponibilité) |
| **Versionnement sémantique de l'interface** | Comment évoluer sans casser les consommateurs ? |
| **Politique de dépréciation** | Comment retirer proprement un champ/une vue ? |
| **Registre des consommateurs** | Qui utilise quoi ? (impossible de gérer l'impact sans le savoir) |
| **Changelog consommateur** | Comment les tiers apprennent-ils les changements ? |

## État actuel du projet

- Les vues `api.*` sont l'interface publique, mais **rien ne distingue un changement
  interne d'un breaking change** : une migration peut retirer une colonne d'une vue et
  atteindre la prod automatiquement (le pipeline `apply_migration_prod` est auto sur merge —
  puissant, mais sans garde-fou spécifique aux vues exposées).
- Le versionnement existe empiriquement (`api_carto_v2` a été créé quand la V1 ne suffisait
  plus) mais sans doctrine : pas de politique de dépréciation de la V1, pas de date de fin.
- Le registre des consommateurs est partiel : les tokens PostgREST identifient des
  partenaires, mais "qui utilise quel champ" est inconnu.
- `CHANGELOG-metier.md` existe (excellente base) mais il est interne — les partenaires
  n'ont pas de canal dédié.
- L'ambition MIN/data-inclusion (vue `api_data_inclusion`) montre que l'exposition à des
  écosystèmes externes standardisés est déjà une réalité — le schéma data-inclusion est
  d'ailleurs un *contrat de sortie imposé* : un bon exemple à généraliser.

## Mise en place sur ce projet

### 1. Contrat de sortie par vue exposée

Le symétrique exact des contrats amont (fiche 02) — un YAML par vue `api.*` :

```yaml
# contracts/out/api__carto_v2.yml
dataset: api.carto_v2
status: stable            # draft | stable | deprecated
consumers: [carto-front, partenaire-X]
freshness_promise: 24h    # ce qu'on PROMET (≤ ce qu'on mesure, fiche 06)
fields:
  - name: statut
    type: string
    enum: [active, fermee, en_creation]
    stability: stable     # stable | evolving — un champ evolving peut changer avec préavis court
```

- Publié aux partenaires (le YAML lui-même, ou sa projection dans l'OpenAPI PostgREST via
  les `COMMENT ON` de la fiche 07).
- La promesse de fraîcheur est **inférieure ou égale** à ce que l'observabilité mesure
  réellement — on ne promet que ce qu'on tient.

### 2. Doctrine de versionnement

Règles simples, calquées sur le versionnement sémantique :

- **Non cassant** (ajout de champ, de vue) : à tout moment, annoncé dans le changelog
  consommateur. Les clients doivent tolérer les champs inconnus (à écrire dans les CGU
  d'usage de l'API).
- **Cassant** (retrait/renommage de champ, changement de type ou de sémantique, changement
  d'enum) : **jamais en place** — nouvelle vue versionnée (`carto_v3`), coexistence des
  deux versions pendant la période de transition.
- **Sémantique silencieuse** : le pire cas (le champ existe toujours mais ne veut plus dire
  la même chose) — interdit ; c'est un cassant déguisé, donc nouvelle version.

### 3. Politique de dépréciation

Le cycle de vie complet, écrit une fois :

```
stable ──► deprecated (annonce + date de retrait, ≥ 3 mois) ──► retiré
```

- L'annonce part sur le canal partenaires (voir §5) avec la date et le chemin de migration.
- Pendant la dépréciation : suivre l'usage réel de la vue (logs PostgREST / compteur par
  token) — on ne retire que ce qui n'est plus appelé, ou à la date annoncée après relances.
- Appliquer immédiatement à `api.carto` v1 : statut, date de retrait, communication — c'est
  le cas d'école disponible.

### 4. Garde-fou CI sur les vues exposées

Le complément technique indispensable, vu que les migrations partent en prod
automatiquement :

- Un test CI qui **snapshot le schéma des vues `api.*`** (colonnes + types, depuis
  `information_schema`) et échoue si une MR le modifie **sans mettre à jour le contrat de
  sortie correspondant**. Un breaking change devient impossible par inadvertance — il
  demande un acte volontaire et tracé (modifier le contrat = signal en revue de MR).

### 5. Registre des consommateurs et canal de communication

- **Registre** : partenaire, contact, token, vues/champs utilisés (déclaratif à
  l'onboarding + observé via les logs), criticité. C'est ce qui transforme "on peut
  supprimer cette colonne ?" de pari en décision informée.
- **Canal** : un `CHANGELOG-api.md` public (ou une page de doc partenaires) alimenté au
  même rythme que les changelogs existants, + notification directe (email/Mattermost
  partenaires) pour les dépréciations. La discipline de double changelog du projet
  s'étend naturellement à un troisième public : les consommateurs externes.

### 6. Onboarding partenaire

Un partenaire qui arrive reçoit : la doc OpenAPI (générée, enrichie des comments), le
contrat de sortie des vues qui le concernent, le dictionnaire des champs (fiche 07), les
règles du jeu (tolérance aux ajouts, canal d'annonce, SLA de fraîcheur). Une heure de
préparation par partenaire, des mois de malentendus évités.

## Par où commencer

1. Registre des consommateurs actuels (tokens existants + partenaires connus).
2. Contrats de sortie des vues `api.*` actives + doctrine de versionnement/dépréciation
   (2 pages).
3. Test CI de snapshot du schéma des vues exposées.
4. Statuer sur `api.carto` v1 (premier cas de dépréciation formelle).
5. `CHANGELOG-api.md` et canal d'annonce partenaires.

## Pièges connus

- **Versionner à l'infini** : maintenir 4 versions d'une vue est une dette ; la politique
  de dépréciation avec date de retrait est ce qui rend le versionnement soutenable.
- **Le registre déclaratif seul** : les partenaires oublient de dire ce qu'ils utilisent —
  croiser avec l'usage observé (logs par token).
- **Promettre la fraîcheur qu'on n'a pas mesurée** : le contrat de sortie dépend de
  l'observabilité (fiche 06) ; promettre avant de mesurer, c'est préparer un incident de
  confiance.
- **Considérer l'API interne (MIN) comme exposée** : MIN est un consommateur *interne*
  co-évoluant avec la base — lui appliquer la lourdeur du versionnement public serait
  contre-productif. La frontière : ce qu'on ne déploie pas soi-même est externe.

## Aller plus loin

- **Open data / data.gouv** : pour un service public, la publication en open data
  (jeux agrégés, anonymisés) est un horizon naturel — elle exige exactement les briques de
  cette fiche (contrat de sortie, dictionnaire, fraîcheur) plus une licence (Licence
  Ouverte) et un schéma publié (schema.data.gouv.fr, comme data-inclusion). Le travail fait
  ici est directement réutilisable.
- **Standards d'interopérabilité sectoriels** : data-inclusion est déjà intégré ; suivre
  les schémas de l'écosystème inclusion numérique et y contribuer (la standardisation
  amont réduit nos coûts de réconciliation — cf. fiche 04).
- **SLA contractuels et facturation d'API** : hors sujet pour un service public gratuit,
  mais les mécanismes (quotas par token, rate limiting PostgREST/nginx) peuvent devenir
  utiles en cas d'abus d'usage.
- **Data marketplace / data sharing platforms** (Snowflake shares, Delta Sharing) : hors
  d'échelle et hors philosophie — l'API ouverte et l'open data sont les équivalents
  service public.

## Références

- *Data Mesh* (Dehghani) — chapitre "data as a product" (le concept, à extraire de son
  contexte grande entreprise)
- schema.data.gouv.fr, data-inclusion — standards de publication du secteur public français
- PostgREST — OpenAPI generation ; Licence Ouverte / Etalab
