-- ============================================================
-- V085 – Refonte phase 4d : basculer min.membre.structure_id vers SA
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 4d. min.membre représente un
-- membre d'une gouvernance départementale (entité légale qui prend des
-- engagements via subventions/feuilles de route). Sémantiquement = SA.
--
-- Mesures dataspace_dev 2026-05-22 :
--   - 2 180 lignes total, toutes avec structure_id non NULL
-- → Stratégie révisée 2026-05-25 (V073 conserve désormais les antennes via
--   denomination_antenne) : remap par old_main_structure_id direct + fallback
--   (siret, nom) pour les non-winners de vrais doublons exacts.
-- ============================================================

-- 1. DROP ancienne FK vers main.structure
ALTER TABLE min.membre DROP CONSTRAINT IF EXISTS membre_structure_id_fkey;

-- 2. UPDATE structure_id (mapping ms.id -> sa.id).
-- Match direct via old_main_structure_id + fallback (siret, nom). Cf V078
-- pour la logique détaillée.
WITH mapping AS (
  SELECT DISTINCT ms.id AS old_id, sa.id AS new_id
  FROM main.structure ms
  JOIN main.structure_administrative sa
    ON sa.old_main_structure_id = ms.id
    OR (
      sa.siret IS NOT DISTINCT FROM ms.siret
      AND COALESCE(sa.denomination_antenne, ms.nom) = ms.nom
    )
)
UPDATE min.membre m
SET structure_id = mp.new_id
FROM mapping mp
WHERE m.structure_id = mp.old_id;

-- 4. Vérifier 0 orphan
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM min.membre m
  WHERE m.structure_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM main.structure_administrative sa WHERE sa.id = m.structure_id);
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V085 INVARIANT VIOLÉ : % min.membre orphelines', orphans;
  END IF;
END $$;

-- 5. ADD nouvelle FK vers main.structure_administrative
ALTER TABLE min.membre
  ADD CONSTRAINT membre_structure_id_fkey
  FOREIGN KEY (structure_id)
  REFERENCES main.structure_administrative (id);

-- 6. Rapport final
DO $$
DECLARE
  total INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM min.membre WHERE structure_id IS NOT NULL;
  RAISE NOTICE 'V085 migrate FK min.membre : OK (% lignes rattachées à une SA)', total;
END $$;
