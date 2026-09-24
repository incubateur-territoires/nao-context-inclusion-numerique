# État des lieux — adresse canonique ↔ SIRENE

> Synthèse de l'investigation 2026-06 : où on en est, côté **réflexion** et
> côté **code**. Complète `audit-adresse-canonique-sirene.md` (détail des
> mesures et propositions) et `fusion-structures-synthese-po.md` (note PO).

## 1. L'invariant cible

> Une `structure_administrative` **canonique** (`siret NOT NULL` +
> `denomination_antenne IS NULL` + `deleted_at IS NULL`) doit porter
> **l'adresse SIRENE exacte de son SIRET**.
> Sinon → c'est une **antenne** (`denomination_antenne != NULL`), dont
> l'adresse peut légitimement différer.

## 2. La découverte clé sur le pipeline

L'adresse stockée d'une SA = **BAN(adresse SOURCE)**, *pas* l'adresse SIRENE :
l'adresse SIRENE est captée puis **jetée** (jamais persistée hors `import.carto`).

⇒ Pour vérifier la conformité, on **re-géocode l'adresse SIRENE via BAN** et on
compare **BAN↔BAN** (`code_ban` + distance), et non la valeur INSEE brute.
C'est la correction de fond apportée au script de vérification.

## 3. Le diagnostic décisif

- Les canoniques « loin » sont à **99,9 % des singletons** (seule ligne de leur
  SIRET).
- ⇒ Ce **ne sont pas des antennes** : ce sont des **établissements avec une
  adresse stockée fausse** (erreur de géocodage de la source, ou saisie /
  migration non ban-ifiée). Exemple type : Centre Hospitalier de Sarreguemines
  géocodé en Nouvelle-Calédonie (~16 521 km).
- ⇒ La bonne action est le **backfill SIRENE** (re-géocoder l'adresse SIRENE et
  repointer `adresse_id`), **pas** un relabel en antenne — qui recréerait la
  pathologie « SIRET sans canonique ».

**Causes racines des écarts** : aidants-connect + `migrate_ac_addresses.py`
dominent ; MIN crée des structures non géocodées ; id-poste et coop sont quasi
tous conformes.

**Décisions actées** :
- On **abandonne** la modélisation SIREN / hiérarchie siège↔antenne (mesurée
  marginale : 238 SIREN multi-SIRET vs 2 007 SIRET multi-lignes).
- **Pas de traitement spécifique pour les EI** (entrepreneurs individuels) :
  données publiques, acteurs légitimes.

## 4. Les mesures (5 761 canoniques, `dataspace_dev`, seuil « proche » = 200 m)

| Statut | % |
|---|---|
| `OK_PROCHE` (< 200 m du SIRENE) | 76,9 % |
| `MEME_COMMUNE_LOIN` (même commune, > 200 m) | 12,5 % |
| `COMMUNE_DIFFERENTE` | 8,6 % |
| `SANS_ADRESSE_STOCKEE` | 0,9 % |
| `SIRENE_INTROUVABLE` | 1,1 % |

## 5. État du code / des livrables

| Livrable | État |
|---|---|
| `scripts/verifier_adresse_canonique_sirene.py` | ✅ Outil de vérif BAN↔BAN. Flags `--seuil`, `--rapide`, `--limit`, `-o`, `--csv-tout`, `--api-key` ; breakdown par `edited_by`. |
| `docs/audit-adresse-canonique-sirene.md` | ✅ Récap détaillé + propositions (déplacement/renommage, URLs, nom, distance). |
| `docs/fusion-structures-synthese-po.md` | ✅ Note PO (avant/pourquoi, ce qu'on a fait, ce qui manque). |
| `docs/etat-des-lieux-adresse-canonique.md` | ✅ Ce document. |
| Ticket GitHub **#1534** (board SEPT, Produit=Entrepôt, A faire) | ✅ 3 lots : backfill / cause racine AC+MIN / nettoyage non-canoniques par distance. |

**Reproduire les écarts** (le CSV n'est pas versionné — données réservées aux
porteurs de la BDD) :

```bash
# export complet des écarts (édité_by + distance_m)
python3 scripts/verifier_adresse_canonique_sirene.py \
  --api-key "$SIRENE_API_KEY" -o ecarts_canoniques.csv --csv-tout

# vérif rapide (commune uniquement, sans géocodage SIRENE)
python3 scripts/verifier_adresse_canonique_sirene.py --rapide --limit 200
```

## 6. Ce qui reste à faire

1. **Lot 1 — backfill SIRENE** : mode `--apply` du script (re-géocoder l'adresse
   SIRENE et repointer `adresse_id` des singletons non conformes). L'invariant
   §1 tient alors, le nom ne change pas.
2. **Lot 2 — cause racine** : corriger aidants-connect / `migrate_ac_addresses.py`
   et la saisie MIN non géocodée, pour ne plus régénérer d'écarts.
3. **Lot 3 — nettoyage non-canoniques** : comparer la distance des lignes
   non-canoniques à leur canonique.
4. **Cas à part** : 64 `SIRENE_INTROUVABLE` (revue manuelle), 52
   `SANS_ADRESSE_STOCKEE` (dotés par le backfill).

> Note : la migration `V096_…detection_doublon_antenne_via_adresse.sql`
> (comparaison de « frères » internes) est **partiellement obsolète** depuis
> qu'on a conclu au backfill via référentiel SIRENE externe. Non versionnée
> ici, à réviser ou retirer.
