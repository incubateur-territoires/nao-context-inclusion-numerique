# Phase 3 — Test du DAG idposte refondu

> **Statut** : doc opérationnel pour tester localement la bascule du
> DAG `schema-idPoste` vers le nouveau modèle (cf
> [`refonte-structure-plan.md`](refonte-structure-plan.md) phase 3).

## Prérequis

Sur ta machine locale :
- DB `dataspace_dev` à jour avec migrations V068-V080 (phase 1, 2, 3.a)
- Container Airflow démarré (`docker compose -f docker-compose.dev.yml up -d`)
- CSV CoNum disponible dans `data-airflow/conum.csv` (déjà en place)

## Test du DAG en local

### Option A : via Airflow CLI (depuis le container)

```bash
# Vérifier que le DAG charge sans erreur
docker compose -f docker-compose.dev.yml exec airflow \
  airflow dags list-jobs | grep schema-idPoste

# Trigger manuel du DAG avec le profil dev
docker compose -f docker-compose.dev.yml exec airflow \
  airflow dags trigger schema-idPoste \
    --conf '{"db_conn_id": "sonum-dev-db"}'

# Suivre l'exécution
docker compose -f docker-compose.dev.yml exec airflow \
  airflow tasks logs schema-idPoste process_enriched_structure <run_id>
```

### Option B : via l'UI Airflow

1. Ouvrir http://localhost:8080
2. Activer le DAG `schema-idPoste`
3. Trigger manuel avec params `db_conn_id=sonum-dev-db`

## Validation post-run

### 1. Compteurs après run

```bash
DATABASE_URL=postgresql://dataspace:dataspace_dev_password@localhost:5532/dataspace_dev \
  scripts/rapport_all.sh diff snapshots/phase3a_after_fk_migrations_2026-05-22
```

**Diffs attendus** :
- `structure_administrative` : variation cohérente avec le CSV CoNum
  (ajout/UPDATE des structures employeuses CN). Doit rester **0 doublon SIRET**.
- `main.structure` (legacy) : **0 changement** (idposte n'écrit plus dedans).
- `personne_affectations_emploi` : variation cohérente avec les affectations
  CN du CSV (en plus de l'historique idposte existant en V076).
- `main.personne_affectations` (legacy) : **0 changement**.
- `rapport_validation` (postes/contrats/subventions) : **strictement identique**
  au snapshot 3.a, car ces tables n'ont pas changé de schéma — seulement
  leurs FK pointent maintenant vers `structure_administrative`.

### 2. Cas Loir-et-Cher (SIRET 22410001600019)

```sql
-- Si la structure existe dans le CSV CoNum, après run idposte
-- elle doit toujours être 1 seule ligne dans structure_administrative.
SELECT COUNT(*) FROM main.structure_administrative WHERE siret = '22410001600019';
-- Attendu : 1
```

### 3. Pas d'écriture orpheline

```sql
-- Vérifier qu'aucune FK pendante n'est créée
SELECT COUNT(*) FROM main.poste p
WHERE p.structure_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM main.structure_administrative sa WHERE sa.id = p.structure_id);
-- Attendu : 0

SELECT COUNT(*) FROM main.contrat c
WHERE c.structure_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM main.structure_administrative sa WHERE sa.id = c.structure_id);
-- Attendu : 0

SELECT COUNT(*) FROM main.contact_structure_administrative csa
WHERE NOT EXISTS (SELECT 1 FROM main.structure_administrative sa WHERE sa.id = csa.structure_administrative_id);
-- Attendu : 0
```

## En cas d'échec

### Rollback complet

```bash
# Reset la DB locale
PGPASSWORD=dataspace_dev_password psql -h localhost -p 5532 -U dataspace -d dataspace_dev \
  -c "DROP DATABASE dataspace_dev;"
# Puis pg_restore basederef.custom + flyway migrate
```

### Investigation

Si le DAG plante :
- Logs Airflow : `docker compose -f docker-compose.dev.yml logs -f airflow`
- Tâche spécifique : UI Airflow → DAG schema-idPoste → onglet Graph → click tâche → Logs

## Limitations connues phase 3

1. **`structures-similarities-merge` désactivé** : pas de réconciliation
   cross-source automatique après run idposte. Le DAG sera refondu en
   phase 3.c bis ou phase 4 pour pointer sur `structure_administrative`.
2. **`personne-similarities-merge` désactivé** : idem côté personnes.
3. **`structure_columns` sans `nom`** : si MIN affiche le `nom` d'une
   structure d'emploi, il devra basculer sur `denomination_sirene`
   (phase 5).
4. **Triggers commentés dans `schema-idPoste.py`** : à réactiver une fois
   les similarities-merge refondus.

## Une fois validé

Capturer le snapshot post-run :

```bash
DATABASE_URL=postgresql://dataspace:dataspace_dev_password@localhost:5532/dataspace_dev \
  scripts/rapport_all.sh snapshot snapshots/phase3c_after_idposte_run_$(date +%Y-%m-%d)
```

Et commit le snapshot pour la suite (phase 4).
