-- 1) Ajouter la colonne (nullable pour le backfill)
ALTER TABLE main.personne_affectations
ADD COLUMN source CHARACTER VARYING;

ALTER TABLE main.personne_affectations
ADD CONSTRAINT personne_affectations_source_check
CHECK (source IN ('idposte', 'aidants-connect', 'coop'));

-- 2) Backfill : lignes coop (structure_coop_id IS NOT NULL)
UPDATE main.personne_affectations
SET source = 'coop'
WHERE structure_coop_id IS NOT NULL AND source IS NULL;

-- 3) Backfill : personne avec SEULEMENT aidant_connect_id
UPDATE main.personne_affectations pa
SET source = 'aidants-connect'
FROM main.personne p
WHERE pa.personne_id = p.id AND pa.source IS NULL
  AND p.aidant_connect_id IS NOT NULL AND p.cn_pg_id IS NULL;

-- 4) Backfill : personne avec SEULEMENT cn_pg_id
UPDATE main.personne_affectations pa
SET source = 'idposte'
FROM main.personne p
WHERE pa.personne_id = p.id AND pa.source IS NULL
  AND p.cn_pg_id IS NOT NULL AND p.aidant_connect_id IS NULL;

-- 5) Personnes fusionnees : disambiguer par structure
UPDATE main.personne_affectations pa
SET source = 'aidants-connect'
FROM main.structure s
WHERE pa.structure_id = s.id AND pa.source IS NULL
  AND s.structure_ac_id IS NOT NULL AND s.structure_tp_id IS NULL;

UPDATE main.personne_affectations pa
SET source = 'idposte'
FROM main.structure s
WHERE pa.structure_id = s.id AND pa.source IS NULL
  AND s.structure_tp_id IS NOT NULL AND s.structure_ac_id IS NULL;

-- 6) Personne+structure fusionnees : disambiguer par created_at
--    On determine la source dominante de chaque jour a partir des lignes deja resolues,
--    puis on assigne cette source aux lignes restantes creees le meme jour.
UPDATE main.personne_affectations pa
SET source = day_source.dominant_source
FROM (
  SELECT
    created_at::date AS day,
    source AS dominant_source
  FROM (
    SELECT created_at::date, source, count(*) AS nb,
      ROW_NUMBER() OVER (PARTITION BY created_at::date ORDER BY count(*) DESC) AS rn
    FROM main.personne_affectations
    WHERE source IS NOT NULL
    GROUP BY created_at::date, source
  ) ranked
  WHERE rn = 1
) day_source
WHERE pa.source IS NULL
  AND pa.created_at::date = day_source.day;

-- 7) Fallback : si aucune correspondance de date -> aidants-connect
UPDATE main.personne_affectations
SET source = 'aidants-connect'
WHERE source IS NULL;

-- 8) Enforcer NOT NULL
ALTER TABLE main.personne_affectations
ALTER COLUMN source SET NOT NULL;

COMMENT ON COLUMN main.personne_affectations.source IS
  'Source du DAG ayant cree cette affectation : idposte, aidants-connect ou coop.';
