# Audit adresse canonique ↔ SIRENE — récap & propositions

> Objectif : établir l'invariant **« une structure canonique porte l'adresse
> exacte de son SIRET »**, et décider quoi faire des structures qui n'y
> répondent pas. Synthèse de l'investigation 2026-06.

## 1. Modèle & vocabulaire

- **Canonique** : `structure_administrative` avec `siret NOT NULL`,
  `denomination_antenne IS NULL`, `deleted_at IS NULL`. Censée représenter
  fidèlement l'établissement INSEE → son adresse doit être celle du SIRET.
- **Antenne** : `denomination_antenne != NULL` — sous-entité partageant le
  SIRET, à une adresse *différente* de celle du siège.
- Pas de colonne `nom` sur `structure_administrative` : le nom opérationnel
  n'existe que comme **nom legacy** (`main.structure.nom` via
  `old_main_structure_id`). `denomination_sirene` = nom de l'unité légale
  (SIREN), souvent ≠ du nom d'usage.
- On **abandonne** la modélisation SIREN / hiérarchie siège↔antenne :
  mesurée marginale (238 SIREN multi-SIRET vs 2 007 SIRET multi-lignes).

## 2. Découvertes pipeline (cf mémoire `project_sa_adresse_pipeline_ban_source`)

- L'adresse stockée d'une SA = **BAN(adresse SOURCE)**, pas l'adresse SIRENE
  (qui est captée puis jetée, jamais persistée hors `import.carto`).
- La **nature de la source diffère** : `coop_structures_temp.adresse` =
  adresse opérationnelle ; `cn_structures.insee_adresse_*` (id-poste) =
  adresse INSEE directe → id-poste colle au SIRENE, coop peut diverger.
- Ban-ification ~92 % (5 282/5 761 `clef_interop`), trous : saisie MIN
  (`app_python`/`min_scalingo`) et migration one-shot `migrate_ac_addresses.py`.
- ⇒ Pour comparer stocké vs SIRENE, on **re-géocode l'adresse SIRENE via
  BAN** et on compare BAN↔BAN (outil `scripts/verifier_adresse_canonique_sirene.py`).

## 3. Mesures sur les 5 761 canoniques (seuil « proche » = 200 m)

| Statut | n | % |
|---|---|---|
| `OK_PROCHE` (< 200 m du SIRENE) | 4 430 | **76,9 %** |
| `MEME_COMMUNE_LOIN` (même commune, > 200 m) | 719 | 12,5 % |
| `COMMUNE_DIFFERENTE` | 496 | 8,6 % |
| `SANS_ADRESSE_STOCKEE` | 52 | 0,9 % |
| `SIRENE_INTROUVABLE` | 64 | 1,1 % |

Provenance des écarts (`MEME_COMMUNE_LOIN`) : aidants-connect 251,
`migrate_ac_addresses.py` 206, MIN (`min_scalingo` 123 + `app_python` 54),
puis carto/id-poste/coop marginaux. `COMMUNE_DIFFERENTE` : 65 % =
`migrate_ac_addresses.py`. **id-poste et coop sont quasi tous conformes.**

## 4. Diagnostic décisif

- Les « loin » sont à **99,9 % des singletons** (718/719 et 495/496 sont la
  *seule* ligne de leur SIRET).
- Distance médiane des écarts = **2 065 m** ; 460 > 1 km ; 241 > 5 km ;
  certains > 1 000 km (adresse géocodée dans le mauvais département / en
  outre-mer).
- ⇒ Ce **ne sont pas des antennes** : ce sont des **établissements avec une
  adresse stockée fausse** (erreur de géocodage de la source, ou saisie/migration
  non ban-ifiée). Exemple type : « Centre Hospitalier de Sarreguemines »
  géocodé en Nouvelle-Calédonie.
- ⇒ Transformer un singleton en antenne serait une **erreur** : on
  laisserait le SIRET sans canonique (re-création de la pathologie « 2 007
  SIRET sans canonique »), et une antenne sans siège n'a pas de sens.

## 5. Propositions d'action

### 5.a — DÉPLACEMENT (backfill SIRENE) — les ~1 213 singletons loin

Re-géocoder l'adresse SIRENE et **repointer `adresse_id`** → la canonique
repasse `OK_PROCHE`, reste canonique, l'invariant tient. Le nom **ne change
pas**. La « distance de replacement » = distance entre l'adresse fausse
actuelle et l'adresse SIRENE.

Exemples (URL = `…/structure/<id>`, id = `structure_administrative.id`) :

| Structure | source | nom (inchangé) | dénom. SIREN | commune SA→SIRENE | déplacement |
|---|---|---|---|---|---|
| https://mon.inclusion-numerique.anct.gouv.fr/structure/5984 | aidants-connect | Centre Hospitalier de Sarreguemines | CENTRE HOSPITALIER ROBERT PAX | 98818→57631 | ~16 521 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/465 | aidants-connect | CIAS MACS | CENTRE INTERCOMMUNAL D ACTION SOC. | 97311→40284 | ~6 655 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/789 | id-poste | Communauté De Communes Du Cap Corse | COMMUNAUTE DE COMMUNES DU CAP CORSE | 40328→2B043 | ~887 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/3438 | aidants-connect | France services St Omer | COMMUNE DE SAINT OMER | 34172→62765 | ~804 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/439 | aidants-connect | CIAS DU CREONNAIS | CENTRE INTERCOMMUNAL D ACTION SOC. | 59350→33140 | ~698 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/6230 | aidants-connect | CCAS Labruguière | CTRE COM ACTION SOCIALE DE LABRUGUIERE | 76351→81120 | ~682 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/8752 | aidants-connect | Présence Verte | PRESENCE VERTE DES COTES NORMANDES | 26231→50502 | ~645 km |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/2723 | aidants-connect | Médiathèque La Source | COMMUNE DE SALLEBOEUF | 92064→33496 | ~489 km |

(les 8 ci-dessus = têtes de liste ; il y a ~1 213 cas, du km au sub-km.)

### 5.b — RENOMMAGE → antenne — uniquement les multi-lignes (2 cas)

Là où une canonique correcte coexiste déjà avec une ligne distante, on copie
le nom dans `denomination_antenne` (la ligne devient antenne, le siège reste).

| Structure | nom avant (`denomination_antenne`) | nom après | distance | statut |
|---|---|---|---|---|
| https://mon.inclusion-numerique.anct.gouv.fr/structure/5433 | NULL (canonique) | Communauté Agglomération Espace Sud | (commune ≠) | COMMUNE_DIFFERENTE |
| https://mon.inclusion-numerique.anct.gouv.fr/structure/8879 | NULL (canonique) | Mediance 66 | ~694 m | MEME_COMMUNE_LOIN |

→ À valider à l'œil (8879 à 694 m peut aussi n'être qu'une adresse imprécise).

### 5.c — Cas à traiter à part

- **64 `SIRENE_INTROUVABLE`** : SIRET non retrouvé à l'API (radiés/fermés ?).
  Ni backfill ni relabel auto → revue manuelle.
- **52 `SANS_ADRESSE_STOCKEE`** : le backfill SIRENE les doterait d'une adresse.

## 6. Renommage du champ `denomination_antenne` (séparé)

Le nom est trompeur (évoque l'établissement INSEE). Pistes : `denomination_locale`,
`denomination_usage`, `denomination_specifique`. À trancher. Préserver son
rôle d'unicité pour les SA sans SIRET (assos nationales).

## 7. Invariant cible

> **Canonique (`denomination_antenne IS NULL`) ⇒ `adresse_id` = adresse SIRENE
> ban-ifiée du SIRET.** Sinon, c'est une antenne (`denomination_antenne != NULL`),
> dont l'adresse peut différer.

Atteint via le backfill (5.a) pour les non-conformes singletons + relabel
ciblé (5.b) pour les rares multi-lignes. Reste 5.c en manuel.

## Pointeurs

- Script de vérif : `scripts/verifier_adresse_canonique_sirene.py`
  (`--seuil`, `--rapide`, `-o ecarts_canoniques.csv`).
- Export complet des écarts : `ecarts_canoniques.csv` (1 331 lignes,
  `edited_by` + `distance_m`).
