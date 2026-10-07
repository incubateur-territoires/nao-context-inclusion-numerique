# 09 — Historisation : Slowly Changing Dimensions et alternatives

← [Retour au document central](README.md)

## Le concept

Les entités du projet changent lentement dans le temps : une structure déménage, change de
nom, ferme ; un médiateur change de structure, d'email, de visibilité. La question
d'historisation est : **quand une valeur change, que fait-on de l'ancienne ?**

La modélisation dimensionnelle (Kimball) formalise les réponses possibles sous le nom de
**Slowly Changing Dimensions (SCD)** :

| Type | Stratégie | Historique | Usage typique |
|------|-----------|------------|---------------|
| **Type 0** | Valeur figée à la création, jamais modifiée | — | Attributs immuables : date de création, source d'origine, UUID |
| **Type 1** | On écrase (`UPDATE`) | **Perdu** | Quand l'historique n'a aucune valeur (correction de typo) |
| **Type 2** | Nouvelle ligne à chaque changement, l'ancienne est "fermée" | **Complet, requêtable** | Le standard pour l'analyse temporelle |
| **Type 3** | Colonne `valeur_precedente` en plus de la courante | Un seul cran | Rare : transitions ponctuelles (ex. re-découpage administratif) |
| Types 4/6 | Variantes hybrides (table d'historique séparée, combinaisons) | Variable | Le type 4 ≈ notre `audit_trail` (voir plus bas) |

## SCD Type 2 en détail — le standard

Chaque changement crée une nouvelle version de la ligne ; les bornes de validité tracent
la chronologie :

```sql
-- main.structure historisée en SCD2
uuid    | nom               | code_insee | valid_from | valid_to   | is_current
--------+-------------------+------------+------------+------------+-----------
a1b2... | France Services X | 03185      | 2025-06-01 | 2026-03-15 | false
a1b2... | Maison FS X       | 03185      | 2026-03-15 | NULL       | true
```

- **État courant** : `WHERE is_current` (exposé en vue aux consommateurs).
- **État à une date** : `WHERE valid_from <= :d AND (valid_to > :d OR valid_to IS NULL)`.
- Répond à des questions impossibles en Type 1 : "nom de cette structure au 1er janvier ?",
  "évolution du nombre de structures actives par mois ?", "quand ce champ a-t-il changé ?".

Coûts associés, à ne pas sous-estimer :

- La clé primaire devient composite (`uuid + valid_from`) ; toutes les FK et jointures des
  consommateurs doivent choisir "courant" ou "à date".
- Chaque pipeline d'écriture doit détecter les changements (comparaison colonne à colonne
  ou hash de ligne) et fermer/ouvrir les versions — logique délicate à écrire à la main.
- La volumétrie croît avec le rythme de changement (généralement acceptable pour des
  dimensions "lentes").

## État actuel du projet

- `main` est en **Type 1 de fait** : les runs écrasent les valeurs, l'historique est perdu
  au niveau du modèle.
- `main.audit_trail` (V124) est un **Type 4 de fait** : l'historique vit dans une table
  séparée, en jsonb (`create`/`delete` = snapshot, `update` = `{"old","new"}`),
  append-only. Bon pour l'audit ("qui a changé quoi, quand"), peu commode pour l'analyse
  temporelle (reconstituer un état passé = rejouer les deltas jsonb).
- La couche `source` append-only (fiche 01, en cours) historise **ce que les sources
  envoient** — c'est une historisation côté amont, pas côté modèle métier.

## Position pour ce projet : ne pas passer `main` en SCD2

Trois besoins distincts se cachent derrière "l'historisation", et chacun a déjà (ou peut
avoir) une réponse moins coûteuse que le SCD2 :

| Besoin | Question type | Réponse retenue |
|--------|---------------|-----------------|
| **Audit** | "Qui a modifié ce champ, quand, ancienne valeur ?" | `main.audit_trail` (V124) — en place |
| **Reproductibilité** | "Que disait la source coop en mars ?" / "rejouer à date" | Couche `source` append-only (fiche 01) |
| **Analyse temporelle** | "Évolution des structures actives par département par mois ?" | **Snapshots périodiques** dans `dataviz` (voir ci-dessous) |

Pourquoi pas SCD2 sur `main` :

1. **Intrusif pour tous les consommateurs** : MIN, les vues `api` (PostgREST) et `dataviz`
   devraient être refondus pour filtrer `is_current` et gérer la clé composite. Le coût de
   refonte dépasse largement la valeur, pour des questions déjà couvertes par ailleurs.
2. **La décision audit_trail est prise** (V124) et cohérente : `main` reste "état courant",
   simple pour MIN ; l'historique vit à côté.
3. Le SCD2 se justifie quand l'analyse temporelle est un besoin *central* et *quotidien* —
   ce n'est pas (encore) le cas ici.

### La réponse au besoin analytique : snapshots périodiques

Si le besoin "évolution dans le temps" se confirme côté dataviz :

```sql
CREATE TABLE dataviz.snapshot_structure (
    snapshot_date date NOT NULL,
    -- colonnes de main.structure (ou le sous-ensemble utile à l'analyse)
    ...
);
-- Tâche Airflow mensuelle (ou hebdo) :
INSERT INTO dataviz.snapshot_structure
SELECT current_date, s.* FROM main.structure s;
```

- 90 % de la valeur analytique du SCD2 (tendances, comparaisons période à période) pour
  5 % de sa complexité : aucune modification de `main` ni des consommateurs.
- Granularité temporelle limitée à la fréquence du snapshot — suffisant pour des
  indicateurs mensuels, pas pour du "à la seconde" (qui relève de l'audit_trail).
- Metabase requête ces tables directement.

### Si le besoin SCD2 devient réel : dbt snapshots

En cas d'adoption de dbt (fiche 05), la fonctionnalité **`dbt snapshot`** produit du SCD2
automatiquement (colonnes `dbt_valid_from`/`dbt_valid_to`, détection de changement par
`timestamp` ou `check` des colonnes) — sans écrire la logique de versionnement à la main :

```sql
{% snapshot structure_scd %}
{{ config(target_schema='history', unique_key='uuid',
          strategy='check', check_cols='all') }}
SELECT * FROM {{ ref('structures') }}
{% endsnapshot %}
```

Le SCD2 vivrait alors dans un schéma `history` dédié, consommé par `dataviz` uniquement —
`main` et ses consommateurs restent intacts. C'est la voie d'évolution recommandée si les
snapshots périodiques montrent leurs limites.

## Grille de décision par attribut

Tous les champs ne méritent pas le même traitement — à croiser avec le dictionnaire de
données (fiche 07) :

| Attribut | Type recommandé | Pourquoi |
|----------|-----------------|----------|
| UUID, source d'origine, date de création | Type 0 | Immuables par définition |
| Correction de typo, enrichissement (géocodage rejoué) | Type 1 + audit_trail | Le changement n'a pas de sens métier temporel |
| Nom, adresse, statut, rattachement d'un médiateur | Type 1 en `main` + snapshot/`dbt snapshot` côté analytique | Sens métier temporel, servi hors de `main` |
| Choix de visibilité d'une personne | Type 1 strict, propagation immédiate partout | Donnée de consentement : l'ancienne valeur ne doit pas rester exposée (RGPD, fiche 07) |

## Pièges connus

- **SCD2 "parce que c'est l'état de l'art"** : c'est un outil pour un besoin analytique
  précis, pas un badge de maturité. À cette échelle, l'adopter sans besoin avéré ajoute de
  la complexité partout pour de la valeur nulle part.
- **SCD2 artisanal** : écrire soi-même la détection de changement et la fermeture de
  versions est un nid à bugs (chevauchements de périodes, versions jamais fermées). Si
  SCD2 il y a, passer par `dbt snapshot`.
- **Mélanger audit et analyse** : reconstituer des séries temporelles depuis
  `audit_trail` (deltas jsonb) est douloureux et lent — c'est le signe qu'il faut des
  snapshots, pas plus de jsonb.
- **Historiser des données personnelles sans doctrine** : chaque couche d'historisation
  (audit_trail, snapshots, history) doit être couverte par le registre et la politique de
  rétention/suppression (fiche 07) — un droit à l'effacement doit se propager à
  l'historique aussi.

## Références

- Kimball — *The Data Warehouse Toolkit* (chapitres SCD, la référence d'origine)
- dbt — *Snapshots* (documentation officielle, SCD2 automatisé)
- Fiches liées : [01 — couches et audit_trail](architecture-medallion.md),
  [05 — dbt](transformations-elt-dbt.md), [07 — rétention et RGPD](gouvernance-catalogue.md)
