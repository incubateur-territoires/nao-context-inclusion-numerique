# Recale dates de mise à jour des lieux d'inclusion

Recale `updated_at_carto` / `updated_at_coop` de `main.lieu_inclusion` sur les
dates réellement portées par les flux amont. `updated_at` étant une colonne
calculée (`GREATEST` des colonnes source, cf. migration V116), le `date_maj`
exposé sur `api.carto` est recalé mécaniquement.

## Règles

| Le lieu a…                             | Source de la date                                                        | Colonne recalée    |
|----------------------------------------|--------------------------------------------------------------------------|--------------------|
| `structure_cartographie_nationale_id` | `date_maj` du payload du **dernier run** de `source.carto__structures`   | `updated_at_carto` |
| `structure_coop_id`                    | `coop.lieu_inclusion.modification`                                       | `updated_at_coop`  |
| les deux ids                           | les deux sources                                                          | les deux colonnes  |

- La date source **fait foi et remplace** la valeur actuelle, même si elle est
  plus ancienne (correction des dates gonflées par le seed V115).
- Une date source NULL, vide ou hors format n'écrase jamais une valeur
  existante.
- Les lieux dont l'id est absent de la source (id carto absent du dernier run,
  id coop absent de `coop.lieu_inclusion`) sont laissés inchangés et comptés
  dans le rapport.
- Idempotent : ré-exécutable sans effet si les dates sont déjà recalées.

## Usage

```bash
uv run main.py <DSN>              # dry-run : compte, ne modifie rien
uv run main.py <DSN> --execute    # applique les mises à jour
```

Exemple :

```bash
uv run main.py postgresql://min:min@localhost:5432/min --execute
```
