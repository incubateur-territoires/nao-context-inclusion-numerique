# Tests et rapports de validation des données

Ce répertoire contient les tests de validation des données de la base de données dataspace, ainsi que des scripts de rapport pour le suivi des données.

## Prérequis

```bash
pip install psycopg2-binary pytest
```

Ou avec le fichier requirements :

```bash
pip install -r tests/requirements-tests.txt
```

## Configuration

Les scripts utilisent la variable d'environnement `DATABASE_URL` pour se connecter à la base de données :

```bash
export DATABASE_URL=postgresql://min:min@localhost:5432/min
```

## Scripts de rapport

Les trois scripts de rapport supportent les mêmes modes d'utilisation :

| Mode | Description |
|------|-------------|
| **Simple** | Génère un rapport de l'état actuel |
| **Snapshot** | Sauvegarde l'état actuel en JSON |
| **Diff snapshot** | Compare un snapshot avec l'état actuel |
| **Diff URLs** | Compare deux bases de données |

### Formats de sortie

Tous les scripts supportent les formats : `text` (défaut), `json`, `csv`, `markdown`

```bash
python scripts/rapport_*.py --format json
python scripts/rapport_*.py -f csv -o rapport.csv
```

---

## rapport_comptage.py

Compte le nombre d'enregistrements par table principale.

**Tables comptées** : `main.personne`, `main.structure`, `main.personne_affectations`, `main.poste`, `main.contrat`

```bash
# Rapport simple
DATABASE_URL=... python scripts/rapport_comptage.py

# Sauvegarder un snapshot avant DAG
DATABASE_URL=... python scripts/rapport_comptage.py --snapshot -o comptage_avant.json

# Comparer après DAG
DATABASE_URL=... python scripts/rapport_comptage.py --depuis-snapshot comptage_avant.json

# Comparer 2 bases directement
python scripts/rapport_comptage.py --avant URL1 --apres URL2
```

---

## rapport_validation.py

Valide les données des Postes Conseiller Numérique en comparant les valeurs obtenues aux valeurs de référence.

**Catégories validées** :
- Structure Allier (cas de test avec 3 postes)
- Statistiques globales (structures bénéficiaires, bonifications, totaux V1/V2)
- États des postes (rendu, vacant, occupé)
- Contrats (débuts, fins, ruptures)

```bash
# Rapport simple (validation attendu vs obtenu)
DATABASE_URL=... python scripts/rapport_validation.py

# Sauvegarder un snapshot avant DAG
DATABASE_URL=... python scripts/rapport_validation.py --snapshot -o validation_avant.json

# Comparer après DAG (évolution des valeurs obtenues)
DATABASE_URL=... python scripts/rapport_validation.py --depuis-snapshot validation_avant.json

# Comparer 2 bases directement
python scripts/rapport_validation.py --avant URL1 --apres URL2
```

---

## rapport_personnes.py

Génère des statistiques sur les personnes à partir de la vue `min.personne_enrichie`.

**Métriques collectées** :
- Totaux (personnes dans la vue et table source)
- Types d'accompagnateurs (médiateurs, aidants numériques)
- Statuts actuels (en poste, conseillers numériques, coordinateurs actifs)
- Labellisations (Aidant Connect, coordinateurs)
- Identifiants (conseiller_numerique_id, cn_pg_id)
- Emploi (personnes avec structure employeuse)

```bash
# Rapport simple
DATABASE_URL=... python scripts/rapport_personnes.py

# Sauvegarder un snapshot avant DAG
DATABASE_URL=... python scripts/rapport_personnes.py --snapshot -o personnes_avant.json

# Comparer après DAG
DATABASE_URL=... python scripts/rapport_personnes.py --depuis-snapshot personnes_avant.json

# Comparer 2 bases directement
python scripts/rapport_personnes.py --avant URL1 --apres URL2
```

---

## Workflow typique : avant/après DAG

```bash
# 1. Avant le DAG : sauvegarder les snapshots
DATABASE_URL=... python scripts/rapport_comptage.py --snapshot -o snapshots/comptage_avant.json
DATABASE_URL=... python scripts/rapport_validation.py --snapshot -o snapshots/validation_avant.json
DATABASE_URL=... python scripts/rapport_personnes.py --snapshot -o snapshots/personnes_avant.json

# 2. Exécuter le DAG
# ...

# 3. Après le DAG : générer les rapports différentiels
DATABASE_URL=... python scripts/rapport_comptage.py --depuis-snapshot snapshots/comptage_avant.json -f markdown -o rapports/comptage_diff.md
DATABASE_URL=... python scripts/rapport_validation.py --depuis-snapshot snapshots/validation_avant.json -f markdown -o rapports/validation_diff.md
DATABASE_URL=... python scripts/rapport_personnes.py --depuis-snapshot snapshots/personnes_avant.json -f markdown -o rapports/personnes_diff.md
```

---

## Exécution des tests unitaires (pytest)

```bash
# Tous les tests
DATABASE_URL=... pytest tests/ -v

# Un fichier ou un test par nom
DATABASE_URL=... pytest tests/test_idposte_structure_update.py -v
DATABASE_URL=... pytest tests/ -v -k "affectation"
```

## Structure des fichiers

| Fichier | Description |
|---------|-------------|
| `conftest.py` | Configuration pytest, fixtures de connexion DB |
| `rapport_comptage.py` | Rapport de comptage par table |
| `rapport_validation.py` | Rapport de validation (attendu vs obtenu) |
| `rapport_personnes.py` | Rapport sur les personnes (vue personne_enrichie) |
| `requirements-tests.txt` | Dépendances Python |

## Valeurs de référence

### Structure Allier (ID 26941)

Cas de test basé sur des données réelles du Département de l'Allier avec 3 postes :

| Poste | V1 attendu | V2 attendu |
|-------|------------|------------|
| 186 | 100 000 € | 57 500 € |
| 187 | 0 € | 57 500 € |
| 4496 | 50 000 € | 0 € |

### Statistiques globales

| Métrique | Valeur de référence |
|----------|---------------------|
| Structures bénéficiaires V1/V2 | 3 623 |
| Structures bonif 7 500 € | 2 110 |
| Structures bonif 10 125 € | 130 |
| V1 total convention | 220 000 000 € |
| V1 total versé | 220 000 000 € |
| V2 total convention | 127 000 000 € |
| V2 total versé | 119 000 000 € |

### États des postes

| État | Valeur de référence |
|------|---------------------|
| Rendu | 3 224 |
| Vacant | 1 086 |
| Occupé | 3 177 |

### Contrats

| Métrique | Valeur de référence |
|----------|---------------------|
| Débuts de contrats | 5 016 |
| Fins de contrats | 3 881 |
| Ruptures de contrats | 2 355 |

## Principe de fonctionnement

Ces scripts fonctionnent en mode **lecture seule** :
- Ils ne modifient pas les données en base (connexion readonly)
- Les rapports de validation comparent les valeurs retournées par les requêtes SQL aux valeurs de référence
- Les rapports différentiels comparent deux états (snapshot vs actuel, ou deux bases)

## Mise à jour des valeurs de référence

Pour mettre à jour les valeurs de référence, modifier les constantes dans :
- `rapport_validation.py` : dictionnaire `REFERENCES` dans la classe `CollecteurValidation`

## Documentation associée

- [Documentation technique des postes CoNum](/home/beta/Dev/min/docs/postes-conseiller-numerique.md)
- [ETL IdPoste](/home/beta/Dev/dataspace/etl/README-IdPoste.md)
