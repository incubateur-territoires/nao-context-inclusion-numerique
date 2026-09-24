# Système de subventions des postes Conseiller Numérique

## Vue d'ensemble

Le dispositif Conseiller Numérique France Services bénéficie de subventions de l'État pour financer les postes. Ce document décrit le modèle de données et les règles de traitement des subventions dans le système.

## Architecture générale

```
CSV Source (CoNum) - Fichier de pilotage
    ↓
Transformation ETL (postes_conum.py)
    ↓
CSV Intermédiaire (subvention.csv)
    ↓
Table PostgreSQL (main.subvention)
    ↓
Vues métier
    ├── min.postes_conseiller_numerique_synthese (analyse)
    └── dataviz.poste (visualisation Metabase)
    ↓
Rapports et tableaux de bord
```

## Les deux enveloppes de financement

### Enveloppe V1 - Lancement initial (Plan France Relance)

| Caractéristique | Détail |
|-----------------|--------|
| **Source** | DGCL (Direction Générale des Collectivités Locales) |
| **Période** | 2021-2023 (lancement du dispositif) |
| **Montant de base** | 50 000 € par poste sur 24 mois |
| **Bonification** | ❌ Pas de bonification en V1 |
| **Objectif** | Financement initial des postes (Plan France Relance) |

### Enveloppe V2 - Renouvellement

| Caractéristique | Détail |
|-----------------|--------|
| **Sources** | DITP (Direction Interministérielle de la Transformation Publique)<br/>DGE (Direction Générale des Entreprises) |
| **Période** | 2023-2025 (renouvellement) |
| **Montant de base** | 50 000 € par poste sur 24 mois |
| **Bonifications** | ✅ 7 500 € (QPV) ou 10 125 € (QPV+) selon territoire |
| **Objectif** | Pérennisation et extension du dispositif |

## Modèle de données

### Structure du CSV source

Le fichier CoNum contient **une ligne par conseiller numérique** affecté à un poste.

**Colonnes essentielles** :

```
id_poste                                           # Identifiant du poste
id_cn                                              # Identifiant du conseiller

# V1 - DGCL
montant_subventions_total_(=ae_total)_v1           # Montant V1 (pas de bonif)
montant_versement_dgcl                             # Montant versé V1
avoir_v1                                           # Avoirs V1
date_début/signature_convention_v1                 # Début convention V1
date_fin_convention_v1                             # Fin convention V1
date_début_financement_dgcl                        # Début financement DGCL
date_de_fin_financement_dgcl                       # Fin financement DGCL
mois_consommés_sur_la_période_de_financement_dgcl  # Mois utilisés DGCL

# V2 - DITP/DGE
montant_subventions_total_(=ae_total)              # Montant TOTAL V2 (subv + bonif)
bonifications_découlant_du_lieu_de_permanence      # Bonification seule (0, 7500, 10125)
avoir_v2                                           # Avoirs V2
montant_versement_1e_tranche                       # 1er versement V2
montant_versement_2e_tranche                       # 2e versement V2
montant_versement_3e_tranche                       # 3e versement V2
date_versement_1e_tranche                          # Date 1er versement
date_versement_2e_tranche                          # Date 2e versement
date_versement_3e_tranche                          # Date 3e versement

# DITP
date_début/signature_convention_v2                 # Début convention V2
date_fin_convention_v2                             # Fin convention V2
date_début_financement_ditp                        # Début financement DITP
date_de_fin_financement_ditp                       # Fin financement DITP
mois_consommés_sur_la_période_de_financement_ditp  # Mois utilisés DITP

# DGE
date_début_financement_dge                         # Début financement DGE
date_de_fin_financement_dge                        # Fin financement DGE
mois_consommés_sur_la_période_de_financement_dge   # Mois utilisés DGE
```

**Exemple concret** :

```csv
id_poste,id_cn,montant_subventions_total_(=ae_total)_v1,montant_subventions_total_(=ae_total),bonifications_découlant_du_lieu_de_permanence
186,1234,50000,57500,7500
186,5678,50000,57500,7500
187,9012,50000,57500,7500
4496,3456,50000,0,0
```

→ Poste 186 : 2 conseillers, V1 = 50000€, V2 = 57500€ (dont 7500€ bonif QPV)
→ Poste 187 : 1 conseiller, V1 = 50000€, V2 = 57500€ (dont 7500€ bonif QPV)
→ Poste 4496 : 1 conseiller, V1 = 50000€, pas de V2

### Table PostgreSQL `main.subvention`

**Une ligne par poste** (après agrégation des conseillers).

```sql
CREATE TABLE main.subvention (
    id SERIAL PRIMARY KEY,
    poste_id INTEGER REFERENCES main.poste(id),

    -- DGCL (V1)
    date_debut_convention_dgcl DATE,
    date_debut_financement_dgcl DATE,
    date_fin_convention_dgcl DATE,
    date_fin_financement_dgcl DATE,
    mois_utilises_periode_financement_dgcl SMALLINT,
    montant_subvention_v1 BIGINT,              -- Subvention V1 (pas de bonif)
    montant_versement_v1 BIGINT,               -- Versé V1
    montant_avoir_v1 BIGINT,                   -- Avoirs V1

    -- DITP (V2)
    date_debut_convention_ditp DATE,
    date_debut_financement_ditp DATE,
    date_fin_convention_ditp DATE,
    date_fin_financement_ditp DATE,
    mois_utilises_periode_financement_ditp SMALLINT,

    -- DGE (V2)
    date_debut_convention_dge DATE,
    date_debut_financement_dge DATE,
    date_fin_convention_dge DATE,
    date_fin_financement_dge DATE,
    mois_utilises_periode_financement_dge SMALLINT,

    -- Montants V2
    montant_subvention_v2 BIGINT,              -- TOTAL V2 (subv + bonif) ⚠️
    montant_bonification_v2 BIGINT,            -- Bonification seule
    montant_avoir_v2 BIGINT,                   -- Avoirs V2

    -- Versements V2
    versement_1_v2 BIGINT,
    versement_2_v2 BIGINT,
    versement_3_v2 BIGINT,
    date_versement_1_v2 DATE,
    date_versement_2_v2 DATE,
    date_versement_3_v2 DATE
);
```

**⚠️ Attention** : `montant_subvention_v2` contient le **TOTAL** (subvention + bonification), ce n'est pas intuitif mais c'est la structure actuelle.

## Règles de transformation ETL

### 1. Agrégation par poste

Le CSV source a **plusieurs lignes par poste** (une par conseiller). Les données sont agrégées :

```python
data_grouped = data.groupby('id_poste', as_index=False).agg(agg_dict)
```

### 2. Stratégies d'agrégation

| Type de colonne | Stratégie | Raison |
|-----------------|-----------|--------|
| **Montants V1 et V2** | `SUM` | Additionner les montants de tous les conseillers |
| **Bonifications V2** | `MAX` | Même poste = même bonif (éviter multiplication) |
| **Dates et conventions** | `FIRST` | Identiques pour tous les conseillers d'un poste |

**Exemple d'agrégation V1** :

```python
# CSV source
Poste 123, Conseiller A : 50000€
Poste 123, Conseiller B : 50000€

# Après agrégation (SUM)
Poste 123 : montant_subvention_v1 = 100000€ ✓
```

**Exemple d'agrégation V2** :

```python
# CSV source
Poste 123, Conseiller A : total=57500€, bonif=7500€
Poste 123, Conseiller B : total=57500€, bonif=7500€

# Après agrégation
Poste 123 : montant_subvention_v2 = SUM(57500, 57500) = 115000€ ✓
Poste 123 : montant_bonification_v2 = MAX(7500, 7500) = 7500€ ✓
```

**⚠️ Pourquoi MAX pour les bonifications ?**

Si on utilisait `SUM` :
```python
Poste 123 : montant_bonification_v2 = SUM(7500, 7500) = 15000€ ❌
```
C'est incorrect car la bonification est une propriété du **lieu de permanence** (territoire prioritaire), pas du conseiller. Tous les conseillers d'un même poste ont la même bonification.

### 3. Calcul des montants dans le CSV intermédiaire

```python
# V1 - Simple, pas de bonification
montant_subvention_v1 = _parse_int(montant_subventions_total_v1)  # Ex: 100000

# V2 - Total inclut les bonifications
montant_total_v2 = _parse_int(montant_subventions_total)  # Ex: 115000
montant_bonif_v2 = _parse_int(bonifications_lieu_permanence)  # Ex: 7500

# Stockage dans la table
montant_subvention_v2 = montant_total_v2  # 115000 (total avec bonif)
montant_bonification_v2 = montant_bonif_v2  # 7500 (bonif seule)
```

### 4. Gestion des valeurs NULL

La fonction `_parse_int` convertit les valeurs vides ou 0 en `NULL` :

```python
def _parse_int(value):
    # ...
    if pd.notna(val) and val == 0:
        return pd.NA  # NULL
    return val
```

Cela signifie qu'un montant de 0€ est stocké comme `NULL` en base.

## Vues PostgreSQL

### Vue `min.postes_conseiller_numerique_synthese`

Vue d'analyse qui **décompose** le total V2 pour exposer la subvention de base :

```sql
-- Subvention de BASE (sans bonification)
COALESCE(s.montant_subvention_v1, 0) as subvention_v1,
0 as bonification_v1,  -- Pas de bonif en V1

-- V2 : on soustrait la bonif pour obtenir la base
COALESCE(s.montant_subvention_v2, 0) - COALESCE(s.montant_bonification_v2, 0) as subvention_v2,
COALESCE(s.montant_bonification_v2, 0) as bonification_v2,

-- Total cumulé V1 + V2 (sans double comptage des bonifications)
COALESCE(s.montant_subvention_v1, 0) + COALESCE(s.montant_subvention_v2, 0) as montant_subvention_cumule
```

**Exemple de calcul** :

| Stockage table | Exposition vue | Détail |
|----------------|----------------|--------|
| `montant_subvention_v1` = 100000 | `subvention_v1` = 100000 | V1 sans bonif |
| `montant_subvention_v2` = 115000 | `subvention_v2` = 107500 | 115000 - 7500 |
| `montant_bonification_v2` = 7500 | `bonification_v2` = 7500 | Bonif seule |
| - | `montant_subvention_cumule` = 215000 | 100000 + 115000 |

### Vue `dataviz.poste`

Vue pour Metabase qui crée **3 lignes virtuelles par poste** (DGCL, DITP, DGE) pour faciliter les analyses par source de financement.

**Structure** :

```sql
-- Ligne DGCL (V1)
SELECT
    ...
    'DGCL' AS source_de_financement,
    subvention.montant_subvention_v1 AS "montant_subventions_hors_bonification",
    'Non' AS territoire_prioritaire,
    NULL AS "bonification découlant du lieu de permanence",
    subvention.montant_subvention_v1 AS "montant_subventions_total"
FROM ...
WHERE subvention.montant_subvention_v1 IS NOT NULL

UNION ALL

-- Ligne DITP (V2)
SELECT
    ...
    'DITP' AS source_de_financement,
    subvention.montant_subvention_v2 - COALESCE(subvention.montant_bonification_v2, 0) AS "montant_subventions_hors_bonification",
    CASE WHEN subvention.montant_bonification_v2 > 0 THEN 'Oui' ELSE 'Non' END AS territoire_prioritaire,
    subvention.montant_bonification_v2 AS "bonification découlant du lieu de permanence",
    subvention.montant_subvention_v2 AS "montant_subventions_total"
FROM ...
WHERE subvention.date_debut_financement_ditp IS NOT NULL

UNION ALL

-- Ligne DGE (V2) - même structure que DITP
...
```

## Bonifications V2 (territoires prioritaires)

### Critères d'attribution

Les bonifications sont attribuées selon le **lieu de permanence** du conseiller numérique :

| Type de territoire | Bonification | Base légale |
|-------------------|--------------|-------------|
| **QPV** (Quartier Prioritaire de la Politique de la Ville) | **7 500 €** | Loi QPV |
| **QPV+** (QPV renforcé) | **10 125 €** | Loi QPV renforcée |
| **Hors QPV** | **0 €** | - |

### Distribution statistique (2026-03-04)

| Bonification | Nombre de postes | Pourcentage |
|--------------|------------------|-------------|
| 7 500 € | 1 350 | 26% |
| 10 125 € | 109 | 2% |
| 0 € | 3 680 | 72% |
| **Total** | **5 139** | **100%** |

### Calcul du montant total V2

```
Montant total V2 = Subvention de base (50 000 €) + Bonification

Exemples :
- Hors QPV : 50 000 € + 0 € = 50 000 €
- QPV : 50 000 € + 7 500 € = 57 500 €
- QPV+ : 50 000 € + 10 125 € = 60 125 €
```

## Métriques et validation

### Totaux nationaux (2026-03-04)

| Métrique | Valeur | Description |
|----------|--------|-------------|
| **Structures bénéficiaires** | 3 598 | Structures distinctes avec subventions |
| **Total V1 convention** | 184 012 807 € | Montant total V1 conventionné |
| **Total V1 versé** | 183 617 329 € | Montant total V1 versé (99.8%) |
| **Total V2 convention** | 252 304 630 € | Montant total V2 conventionné (avec bonif) |
| **Total V2 versé** | 111 710 457 € | Montant total V2 versé (44.3%) |
| **Postes avec bonif 7500€** | 1 350 | Postes en territoire QPV |
| **Postes avec bonif 10125€** | 109 | Postes en territoire QPV+ |

### Requêtes de validation

```sql
-- Structures bénéficiaires
SELECT COUNT(DISTINCT structure_id)
FROM min.postes_conseiller_numerique_synthese
WHERE enveloppes IS NOT NULL;
-- Résultat : 3598

-- Total V1 conventionné
SELECT SUM(subvention_v1 + bonification_v1)
FROM min.postes_conseiller_numerique_synthese;
-- Résultat : 184 012 807

-- Total V2 conventionné (avec bonifications)
SELECT SUM(subvention_v2 + bonification_v2)
FROM min.postes_conseiller_numerique_synthese;
-- Résultat : 252 304 630

-- Postes par type de bonification
SELECT
    CASE
        WHEN bonification_v2 = 7500 THEN 'QPV (7500€)'
        WHEN bonification_v2 = 10125 THEN 'QPV+ (10125€)'
        ELSE 'Hors QPV (0€)'
    END as type_territoire,
    COUNT(*) as nb_postes,
    SUM(subvention_v2 + bonification_v2) as montant_total
FROM min.postes_conseiller_numerique_synthese
WHERE enveloppes LIKE '%V2%'
GROUP BY type_territoire;
```

## Guide de debugging

### Logs de transformation ETL

Le code `postes_conum.py` génère des logs détaillés pendant l'agrégation. Voici un exemple de sortie :

```
[2026-03-04 17:40:54] INFO - [DEBUG] 🎯 VERSION CODE: Subvention OPTION A - Total V2 contient déjà bonifications (2026-03-04)
[2026-03-04 17:40:54] INFO - [DEBUG] 🔎 Colonnes contenant 'montant_subventions_total':
[2026-03-04 17:40:54] INFO - [DEBUG]   - 'montant_subventions_total_(=ae_total)_v1' (longueur: 40)
[2026-03-04 17:40:54] INFO - [DEBUG]   - 'montant_subventions_total_(=ae_total)' (longueur: 37)
[2026-03-04 17:40:54] INFO - [DEBUG] Colonne V2 recherchée: 'montant_subventions_total_(=ae_total)' -> ✅ TROUVÉE
[2026-03-04 17:40:54] INFO - [DEBUG] Colonne bonif recherchée: 'bonifications_découlant_du_lieu_de_permanence' -> ✅ TROUVÉE

[2026-03-04 17:40:54] INFO - [DEBUG] 📊 Bonifications AVANT agrégation (CSV source):
[2026-03-04 17:40:54] INFO - [DEBUG]   - Lignes avec 7500€: 2380
[2026-03-04 17:40:54] INFO - [DEBUG]   - Lignes avec 10125€: 154
[2026-03-04 17:40:54] INFO - [DEBUG]   - POSTES DISTINCTS avec 7500€: 1350
[2026-03-04 17:40:54] INFO - [DEBUG]   - POSTES DISTINCTS avec 10125€: 109
[2026-03-04 17:40:54] INFO - [DEBUG]   - Postes avec bonifications MIXTES: 0
[2026-03-04 17:40:54] INFO - [DEBUG]   - Postes avec 7500 ET 10125: 0

[2026-03-04 17:40:54] INFO - [DEBUG] 📊 Bonifications APRÈS agrégation (max):
[2026-03-04 17:40:54] INFO - [DEBUG]   - 7500€: 1350 postes
[2026-03-04 17:40:54] INFO - [DEBUG]   - 10125€: 109 postes
[2026-03-04 17:40:54] INFO - [DEBUG]   - 0€: 3680 postes
[2026-03-04 17:40:54] INFO - [DEBUG]   - NULL: 0 postes
[2026-03-04 17:40:54] INFO - [DEBUG]   - Autres: 0 postes

[2026-03-04 17:40:54] INFO - Subventions: 8470 lignes CSV -> 5139 postes uniques après agrégation
```

**Interprétation** :
- ✅ 2380 lignes → 1350 postes distincts avec 7500€ (normal, plusieurs conseillers par poste)
- ✅ Aucun poste avec bonifications mixtes
- ✅ 3680 postes avec 0€ de bonification (hors territoire prioritaire)

### Vérifications en base de données

#### 1. Vérifier les bonifications stockées

```sql
-- Distribution des bonifications V2
SELECT
    montant_bonification_v2,
    COUNT(*) as nb_postes,
    COUNT(DISTINCT poste_id) as nb_postes_distincts
FROM main.subvention
WHERE montant_bonification_v2 IS NOT NULL
GROUP BY montant_bonification_v2
ORDER BY nb_postes DESC;

-- Résultat attendu :
-- 7500  | 1350 | 1350
-- 10125 |  109 |  109
```

#### 2. Vérifier les totaux V1 et V2

```sql
-- Totaux stockés dans la table
SELECT
    COUNT(*) as nb_postes,
    SUM(montant_subvention_v1) as total_v1,
    SUM(montant_subvention_v2) as total_v2_avec_bonif,
    SUM(montant_bonification_v2) as total_bonif_v2,
    SUM(montant_subvention_v2) - SUM(COALESCE(montant_bonification_v2, 0)) as total_v2_sans_bonif
FROM main.subvention;

-- Résultat attendu :
-- nb_postes | total_v1    | total_v2_avec_bonif | total_bonif_v2 | total_v2_sans_bonif
-- 5139      | 184 012 807 | 252 304 630         | (à calculer)   | (à calculer)
```

#### 3. Vérifier la cohérence avec les vues

```sql
-- Comparer table vs vue
SELECT
    'Table' as source,
    SUM(montant_subvention_v2) as total_v2
FROM main.subvention
UNION ALL
SELECT
    'Vue' as source,
    SUM(subvention_v2 + bonification_v2) as total_v2
FROM min.postes_conseiller_numerique_synthese;

-- Les deux lignes doivent avoir le même total
```

#### 4. Identifier les écarts potentiels

```sql
-- Postes avec des montants V2 sans bonifications
SELECT
    poste_id,
    montant_subvention_v2,
    montant_bonification_v2
FROM main.subvention
WHERE montant_subvention_v2 IS NOT NULL
  AND montant_bonification_v2 IS NULL;

-- Postes avec incohérence (montant_subvention_v2 < montant_bonification_v2)
SELECT
    poste_id,
    montant_subvention_v2,
    montant_bonification_v2,
    montant_subvention_v2 - montant_bonification_v2 as subvention_base
FROM main.subvention
WHERE montant_subvention_v2 IS NOT NULL
  AND montant_bonification_v2 IS NOT NULL
  AND montant_subvention_v2 < montant_bonification_v2;
-- Cette requête ne doit retourner AUCUNE ligne
```

#### 5. Analyser les postes d'un département spécifique

```sql
-- Exemple : département de l'Allier (structure_id = 26941)
SELECT
    p.poste_conum_id,
    s.montant_subvention_v1,
    s.montant_subvention_v2,
    s.montant_bonification_v2,
    s.montant_subvention_v2 - COALESCE(s.montant_bonification_v2, 0) as subvention_v2_base,
    s.montant_subvention_v2 as total_v2
FROM main.subvention s
JOIN main.poste p ON p.id = s.poste_id
WHERE p.structure_id = 26941
ORDER BY p.poste_conum_id;

-- Vérifier les résultats attendus (test Allier) :
-- Poste 186: V1=50000, V2=57500 (dont bonif=7500)
-- Poste 187: V1=50000, V2=57500 (dont bonif=7500)
-- Poste 4496: V1=50000, V2=NULL
```

### Problèmes courants et solutions

#### Problème 1 : Bonifications multipliées

**Symptôme** : Total V2 trop élevé, bonifications avec valeurs étranges (15000, 22500, etc.)

**Cause** : Agrégation avec `SUM` au lieu de `MAX`

**Solution** :
```python
# ❌ FAUX
agg_dict['bonifications_découlant_du_lieu_de_permanence'] = 'sum'

# ✅ CORRECT
agg_dict['bonifications_découlant_du_lieu_de_permanence'] = 'max'
```

#### Problème 2 : Double comptage des bonifications

**Symptôme** : Montant total trop élevé dans les vues

**Cause** : Addition de `subvention_v2 + bonification_v2` alors que `subvention_v2` contient déjà les bonifications

**Solution** :
```sql
-- ❌ FAUX : double comptage
SELECT montant_subvention_v2 + montant_bonification_v2 FROM main.subvention;

-- ✅ CORRECT : le total est déjà dans montant_subvention_v2
SELECT montant_subvention_v2 FROM main.subvention;

-- OU si vous voulez la décomposition
SELECT
    montant_subvention_v2 - COALESCE(montant_bonification_v2, 0) as subvention_base,
    montant_bonification_v2 as bonification,
    montant_subvention_v2 as total
FROM main.subvention;
```

#### Problème 3 : Écart entre lignes CSV et postes distincts

**Symptôme** : "On attend 2380 structures avec bonif 7500€ mais on n'en a que 1350"

**Cause** : Confusion entre le nombre de lignes CSV (conseillers) et le nombre de postes distincts

**Solution** : Les valeurs de référence doivent compter les **postes distincts**, pas les lignes CSV

```python
# ✅ CORRECT dans rapport_validation.py
'structures_bonif_7500': 1350,  # Postes distincts

# ❌ FAUX
'structures_bonif_7500': 2380,  # Lignes CSV (plusieurs conseillers par poste)
```

#### Problème 4 : Colonnes avec espaces dans les noms

**Symptôme** : Colonne non trouvée, valeurs NULL alors que le CSV a des données

**Cause** : Espaces en début/fin de nom de colonne dans le CSV

**Solution** : Toujours faire un `strip()` sur les noms de colonnes :
```python
data.columns = data.columns.str.strip()
```

### Scripts de diagnostic

#### Script 1 : Vérifier un poste spécifique

```sql
-- Analyser un poste précis (exemple : poste 186)
WITH poste_info AS (
    SELECT
        p.id as poste_id,
        p.poste_conum_id,
        p.structure_id,
        st.nom as structure_nom
    FROM main.poste p
    LEFT JOIN main.structure st ON st.id = p.structure_id
    WHERE p.poste_conum_id = 186
)
SELECT
    pi.*,
    s.montant_subvention_v1,
    s.montant_versement_v1,
    s.montant_subvention_v2,
    s.montant_bonification_v2,
    s.montant_subvention_v2 - COALESCE(s.montant_bonification_v2, 0) as subvention_v2_base,
    s.versement_1_v2 + COALESCE(s.versement_2_v2, 0) + COALESCE(s.versement_3_v2, 0) as total_verse_v2
FROM poste_info pi
LEFT JOIN main.subvention s ON s.poste_id = pi.poste_id;
```

#### Script 2 : Rapport complet de validation

```sql
-- Reproduire les métriques du rapport de validation
SELECT
    'Structures bénéficiaires' as metrique,
    COUNT(DISTINCT structure_id) as valeur
FROM min.postes_conseiller_numerique_synthese
WHERE enveloppes IS NOT NULL

UNION ALL

SELECT 'Structures bonif 7500€', COUNT(*)
FROM min.postes_conseiller_numerique_synthese
WHERE bonification_v2 = 7500

UNION ALL

SELECT 'Structures bonif 10125€', COUNT(*)
FROM min.postes_conseiller_numerique_synthese
WHERE bonification_v2 = 10125

UNION ALL

SELECT 'V2 convention avec bonif', SUM(subvention_v2 + bonification_v2)
FROM min.postes_conseiller_numerique_synthese

UNION ALL

SELECT 'V2 versé', SUM(versement_cumule_v2)
FROM min.postes_conseiller_numerique_synthese

UNION ALL

SELECT 'V1 convention', SUM(subvention_v1 + bonification_v1)
FROM min.postes_conseiller_numerique_synthese

UNION ALL

SELECT 'V1 versé', SUM(versement_cumule_v1)
FROM min.postes_conseiller_numerique_synthese;
```

## Particularités et pièges à éviter

### 1. Différence lignes vs postes

**⚠️ Attention** : Ne pas confondre le nombre de **lignes CSV** et le nombre de **postes distincts**.

```
CSV source : 2 380 LIGNES avec bonification 7500€
→ Plusieurs conseillers par poste

Après agrégation : 1 350 POSTES distincts avec bonification 7500€
→ Un poste peut avoir plusieurs conseillers

Moyenne : 2380 / 1350 ≈ 1.76 conseillers par poste en moyenne
```

### 2. Nom trompeur de `montant_subvention_v2`

La colonne `montant_subvention_v2` dans la table `main.subvention` contient le **TOTAL** (subvention + bonification), pas seulement la subvention de base.

```sql
-- ❌ FAUX : montant_subvention_v2 n'est pas la subvention seule
SELECT montant_subvention_v2 FROM main.subvention;

-- ✅ CORRECT : pour avoir la subvention de base
SELECT montant_subvention_v2 - COALESCE(montant_bonification_v2, 0)
FROM main.subvention;

-- ✅ CORRECT : utiliser la vue qui fait la décomposition
SELECT subvention_v2, bonification_v2
FROM min.postes_conseiller_numerique_synthese;
```

### 3. Agrégation des bonifications

**⚠️ Toujours utiliser `MAX` pour les bonifications**, jamais `SUM` :

```python
# ❌ FAUX
agg_dict['bonifications_découlant_du_lieu_de_permanence'] = 'sum'
# → Un poste avec 2 conseillers = 7500 * 2 = 15000€ (incorrect)

# ✅ CORRECT
agg_dict['bonifications_découlant_du_lieu_de_permanence'] = 'max'
# → Un poste avec 2 conseillers = max(7500, 7500) = 7500€ (correct)
```

### 4. Gestion des NULL

Les montants à 0€ sont convertis en `NULL` par `_parse_int`. Cela peut affecter les calculs :

```sql
-- ⚠️ Attention aux NULL dans les sommes
SELECT SUM(montant_subvention_v2) FROM main.subvention;
-- Les NULL sont ignorés par SUM

-- Utiliser COALESCE pour traiter les NULL comme 0
SELECT SUM(COALESCE(montant_subvention_v2, 0)) FROM main.subvention;
```

### 5. Sources DITP vs DGE

Les deux sources (DITP et DGE) financent la V2, mais avec des dates de début/fin différentes. Un poste peut avoir :
- Uniquement DITP
- Uniquement DGE
- Les deux (rare)

```sql
-- Répartition des sources V2
SELECT
    CASE
        WHEN date_debut_financement_ditp IS NOT NULL AND date_debut_financement_dge IS NOT NULL THEN 'DITP + DGE'
        WHEN date_debut_financement_ditp IS NOT NULL THEN 'DITP seul'
        WHEN date_debut_financement_dge IS NOT NULL THEN 'DGE seul'
        ELSE 'Aucun V2'
    END as source_v2,
    COUNT(*) as nb_postes
FROM main.subvention
GROUP BY source_v2;
```

## Historique et évolution du modèle

### Migration V048 (2026-03-02)

Refonte majeure du modèle de données :

**Avant** : Modèle normalisé
- Plusieurs lignes par poste (une par source : DGCL, DITP, DGE)
- Colonne `source_financement` pour distinguer

**Après** : Modèle dénormalisé
- Une ligne par poste
- Colonnes spécifiques par source (suffixes `_dgcl`, `_ditp`, `_dge`)

**Avantages** :
- Simplification des requêtes
- Meilleure performance (pas de GROUP BY systématique)
- Agrégation déjà faite

### Changements 2026-03-04

1. **Règle de transformation V2** : clarification du fait que `montant_subventions_total_(=ae_total)` contient déjà les bonifications
2. **Agrégation bonifications** : passage de `sum` à `max`
3. **Corrections des vues** : éviter le double comptage des bonifications
4. **Mise à jour des valeurs de référence** : alignement sur les postes distincts

## Références

### Fichiers source

- `etl/transform/ingest/postes_conum.py` : transformation ETL
- `schema-idPoste.py` : DAG Airflow complet
- `database/migrations/V048_*.sql` : structure de la table
- `database/migrations/V049_*.sql` : vue dataviz
- `database/migrations/V050_*.sql` : vue synthèse
- `scripts/rapport_validation.py` : tests et valeurs de référence

### Documentation complémentaire

- [Règles de transformation V2](./regles-subventions-v2.md) : focus technique sur V2
- Schéma de base de données : voir migrations dans `database/migrations/`

### Contacts et support

Pour toute question sur les subventions :
- Équipe ETL : voir `schema-idPoste.py`
- Tests de validation : voir `scripts/rapport_validation.py`
- Logs de debug : activer dans `postes_conum.py`
