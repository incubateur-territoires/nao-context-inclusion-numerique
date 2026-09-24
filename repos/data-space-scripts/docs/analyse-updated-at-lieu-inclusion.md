# Analyse : `updated_at` sur `main.lieu_inclusion`

Date : 2026-06-24

## Constat

Les valeurs de `updated_at` sur `main.lieu_inclusion` ne reflètent pas la réalité des changements de données métier. Elles indiquent plutôt la date du dernier run DAG ayant touché la ligne.

## Mécanisme actuel

### Trigger `updated_at_column()` (V059)

```sql
CREATE OR REPLACE FUNCTION updated_at_column() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.updated_at = now();
    ELSIF NEW IS DISTINCT FROM OLD THEN
        NEW.updated_at = now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

- Compare la **ligne entière** (`NEW IS DISTINCT FROM OLD`).
- Conçu pour éviter les faux `updated_at` lors des réimports quotidiens.

### Trigger manquant sur INSERT

V069 ne crée qu'un trigger **BEFORE UPDATE**. Le trigger **BEFORE INSERT** n'a jamais été ajouté (contrairement aux 10 autres tables dans V059). Conséquence : les nouveaux lieux insérés par les DAGs ont `updated_at = NULL`.

## Problèmes identifiés

### 1. Ping-pong `edited_by` entre DAGs (impact majeur)

Les deux DAGs écrasent `edited_by` systématiquement :

| DAG | Valeur SET | Fichier |
|---|---|---|
| carto-dag | `edited_by = 'carto'` | `carto-dag-import.py:216` |
| coop-dag | `edited_by = 'coop'` | `coop-dag.py:1489` |

Pour un lieu présent dans les deux sources (carto_id + coop_id), à chaque cycle quotidien :

1. **coop-dag** tourne : `edited_by` passe de `'carto'` à `'coop'` → `NEW IS DISTINCT FROM OLD` = true → `updated_at = now()`
2. **carto-dag** tourne : `edited_by` passe de `'coop'` à `'carto'` → `NEW IS DISTINCT FROM OLD` = true → `updated_at = now()`

Résultat : `updated_at` bumpé **2 fois par jour** pour tous les lieux bi-source, sans aucun changement de données métier.

### 2. Ordre non-déterministe des arrays `TEXT[]`

Les champs `typologies`, `services`, `modalites_acces`, `formations_labels`, etc. sont des `TEXT[]`. Côté carto-dag, ils sont produits par `string_to_array(m.xxx, '|')`. L'ordre des éléments peut varier d'un import à l'autre.

PostgreSQL compare les arrays par position : `'{a,b}' IS DISTINCT FROM '{b,a}'` = **true**. Un simple changement d'ordre dans la source (sans changement réel de contenu) provoque un faux `updated_at`.

### 3. `nom` écrasé sans COALESCE dans coop-dag

```sql
-- coop-dag.py:1468
ON CONFLICT (structure_coop_id) DO UPDATE SET
    nom = EXCLUDED.nom,  -- écrasement inconditionnel
    ...
```

Si le nom côté coop diffère légèrement du nom côté carto (casse, espace, abréviation), le `nom` est écrasé → changement détecté → `updated_at` bumpé. Au prochain run carto, le nom carto ré-écrase → nouveau bump.

### 4. INSERT sans `updated_at`

Ni carto-dag ni coop-dag n'incluent `updated_at` dans leurs INSERT. Combiné au trigger INSERT manquant, les nouveaux lieux ont `updated_at = NULL` jusqu'à leur premier UPDATE.

## Récapitulatif par opération

| Opération | Source de `updated_at` | Fiable ? |
|---|---|---|
| Population initiale (V074) | Copié depuis `main.structure.updated_at` | Non (date de la structure, pas du lieu) |
| INSERT carto-dag | NULL (pas de trigger INSERT) | Non |
| INSERT coop-dag | NULL (pas de trigger INSERT) | Non |
| UPDATE carto-dag | `now()` via trigger | Non (ping-pong `edited_by`, arrays) |
| UPDATE coop-dag (`ON CONFLICT DO UPDATE`) | `now()` via trigger | Non (ping-pong `edited_by`, `nom`) |

## Fichiers concernés

- `database/migrations/V059_20260408__smart_updated_at_trigger.sql` — trigger function + triggers INSERT (lieu_inclusion absent)
- `database/migrations/V069_20260521__schema_lieu_inclusion.sql` — CREATE TABLE + trigger UPDATE seul
- `database/migrations/V074_20260522__populate_lieu_inclusion.sql` — population initiale
- `carto-dag-import.py:194-216` — `_CARTO_COMMON_SET` avec `edited_by = 'carto'`
- `carto-dag-import.py:314-328` — UPDATE par carto_id / coop_id
- `carto-dag-import.py:333-355` — INSERT nouveaux lieux
- `coop-dag.py:1457-1492` — INSERT/ON CONFLICT DO UPDATE avec `edited_by = 'coop'`

## Pistes de correction

A discuter. Axes possibles :

1. **Exclure `edited_by` de la comparaison du trigger** (trigger personnalisé pour `lieu_inclusion` qui ignore certaines colonnes).
2. **Unifier `edited_by`** : ne plus l'écraser à chaque run, ou le remplacer par un array de sources.
3. **Ajouter le trigger BEFORE INSERT** manquant + corriger les NULL existants.
4. **Trier les arrays** avant écriture pour éviter les faux changements d'ordre.
