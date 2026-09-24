-- ============================================================
-- V077 – Refonte phase 2 : peuplement personne_affectations_lieu
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 2. Migration des affectations
-- type='lieu_activite' vers la nouvelle table dédiée.
--
-- MAPPING :
-- pa.structure_id → lieu_inclusion.id via old_main_structure_id (1:1, pas
-- de fusion côté lieu).
--
-- Source CHECK in (coop, aidants-connect, carto, min) — pas idposte
-- (idposte ne pose pas de lieu_activite).
--
-- Volume attendu : 14 384 affectations lieu_activite
-- ============================================================

INSERT INTO main.personne_affectations_lieu (
  personne_id, lieu_id,
  source, est_active,
  created_at, updated_at
)
SELECT
  pa.personne_id,
  li.id AS lieu_id,
  pa.source, pa.est_active,
  pa.created_at, pa.updated_at
FROM main.personne_affectations pa
JOIN main.lieu_inclusion li ON li.old_main_structure_id = pa.structure_id
WHERE pa.type = 'lieu_activite'
  AND pa.source IS NOT NULL
  AND pa.source IN ('coop', 'aidants-connect', 'carto', 'min')  -- CHECK côté nouvelle table
  AND pa.personne_id IS NOT NULL
  AND pa.structure_id IS NOT NULL
ON CONFLICT (personne_id, lieu_id, source) DO NOTHING;

-- Vérification
DO $$
DECLARE
  total_new INTEGER;
  total_old INTEGER;
  diff INTEGER;
BEGIN
  SELECT COUNT(*) INTO total_new FROM main.personne_affectations_lieu;
  SELECT COUNT(*) INTO total_old FROM main.personne_affectations
    WHERE type = 'lieu_activite' AND source IS NOT NULL
      AND source IN ('coop', 'aidants-connect', 'carto', 'min')
      AND personne_id IS NOT NULL AND structure_id IS NOT NULL;
  diff := total_old - total_new;
  RAISE NOTICE 'V077 peuplement personne_affectations_lieu : nouveau=% / ancien_valide=% (diff=%)',
    total_new, total_old, diff;
END $$;
