# Delta Rapport

Outil CLI interactif qui compare deux runs d'une table du schema `source` et genere un rapport Markdown des differences (ajouts, suppressions, modifications champ par champ).

## Pre-requis

- Python >= 3.12
- [uv](https://docs.astral.sh/uv/)
- Acces a une base PostgreSQL contenant le schema `source`

## Installation

```bash
cd tools/delta-rapport
uv sync
```

## Utilisation

```bash
uv run main.py <DSN>
```

Exemple :

```bash
uv run main.py postgresql://min:min@localhost:5432/min
```

L'outil est entierement interactif :

1. Liste les tables du schema `source` et demande d'en choisir une
2. Liste les runs disponibles (run_id, date, nombre de lignes)
3. Demande de choisir un run **ancien** et un run **recent**
4. Affiche les champs JSONB disponibles et propose d'en exclure du delta (utile pour ignorer les timestamps ou champs techniques)
5. Genere un fichier `delta_<table>_<date1>_vs_<date2>.md` dans le repertoire courant

## Tables supportees

Chaque table a un champ identifiant configure pour associer les enregistrements entre deux runs :

| Table | Champ identifiant |
|-------|-------------------|
| `ac__aidants` | `aidant_connect_id` |
| `ac__structures` | `structure_ac_id` |
| `ban__adresses` | `id` |
| `carto__structures` | `id` (eclate par `__` en sous-ids) |
| `coop__activites` | `coop_id` |
| `coop__structures` | `structure_coop_id` |
| `coop__utilisateurs` | `coop_id` |
| `frr__zonage` | `id` |
| `idposte__conum` | `id_poste` + `id_structure` + `id_cn` (cle composite) |
| `qpv__zonage` | `id` |
| `sirene__etablissements` | `siret` |

Pour une table non configuree, l'outil liste les champs disponibles dans le JSONB et demande d'en choisir un.

## Rapport genere

Le rapport Markdown contient :

- **Cartouche** : table, runs compares, date, nombre de lignes, totaux ajouts/suppressions/modifications
- **Apercu** : liste des identifiants ajoutes et supprimes
- **Modifications** : tableau avant/apres pour chaque champ modifie, par enregistrement
- **Ajouts** : detail complet de chaque nouvel enregistrement
- **Suppressions** : detail complet de chaque enregistrement disparu
