-- ============================================================
-- V078 – Refonte phase 3.a : migrer main.poste.structure_id → structure_administrative
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 3. Avant de basculer le DAG
-- idposte (3.b) qui écrit dans main.poste, on remappe sa FK structure_id
-- de main.structure vers main.structure_administrative.
--
-- STRATÉGIE (révisée 2026-05-25 — V073 conserve les antennes via
--             denomination_antenne, plus de fusion siret-only) :
--   1. DROP ancienne FK vers main.structure
--   2. UPDATE structure_id : remapper via old_main_structure_id direct
--      (match 1:1 pour chaque legacy qui a sa propre SA) + fallback
--      (siret, nom) pour les non-winners de vrais doublons exacts
--   3. ADD nouvelle FK vers main.structure_administrative
--
-- Volume attendu :
--   - 8 623 main.poste total
--   - 32 sans structure_id (déjà NULL)
--   - 8 591 remappables (presque tous via old_main_structure_id direct
--     post-V073 modifié)
-- ============================================================

-- 1. DROP ancienne FK
ALTER TABLE main.poste DROP CONSTRAINT IF EXISTS poste_structure_id_fkey;

-- 2. UPDATE structure_id (remapping ms.id -> sa.id).
-- 1ère branche : sa.old_main_structure_id = ms.id (match direct du winner).
-- 2ème branche : fallback (siret, nom) pour les non-winners de vrais doublons
-- (même siret + même nom legacy, dont V073 a gardé un seul winner par tuple).
-- COALESCE(sa.denomination_antenne, ms.nom) = ms.nom traite :
--   - sa.denomination_antenne IS NULL (entité unique pour ce siret) -> match toujours
--   - sa.denomination_antenne = "X" (antenne) -> match seulement si ms.nom = "X"
WITH mapping AS (
  SELECT DISTINCT ms.id AS old_id, sa.id AS new_id
  FROM main.structure ms
  JOIN main.structure_administrative sa
    ON sa.old_main_structure_id = ms.id
    OR (
      sa.siret IS NOT DISTINCT FROM ms.siret
      AND COALESCE(sa.denomination_antenne, ms.nom) = ms.nom
    )
  WHERE ms.id IS NOT NULL
)
UPDATE main.poste p
SET structure_id = m.new_id
FROM mapping m
WHERE p.structure_id = m.old_id;

-- 4. Vérification : 0 structure_id orphelin attendu
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM main.poste p
  WHERE p.structure_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM main.structure_administrative sa WHERE sa.id = p.structure_id
    );
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V078 INVARIANT VIOLÉ : % main.poste.structure_id pendants après remapping', orphans;
  END IF;
  RAISE NOTICE 'V078 migration FK main.poste : OK, 0 orphelin';
END $$;

-- 5. ADD nouvelle FK
ALTER TABLE main.poste
  ADD CONSTRAINT poste_structure_id_fkey
  FOREIGN KEY (structure_id) REFERENCES main.structure_administrative (id);
