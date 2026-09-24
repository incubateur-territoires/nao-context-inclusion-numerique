-- ============================================================
-- V086 – Refonte phase 4d : basculer min.utilisateur.structure_id vers SA
-- ============================================================
-- CONTEXTE :
-- Même logique que V085 pour min.utilisateur (utilisateurs MIN rattachés à
-- leur structure employeuse, donc SA).
--
-- Mesures dataspace_dev 2026-05-22 :
--   - 2 157 lignes total, 1 513 avec structure_id non NULL
--   - 1 081 remappables via old_main_structure_id (71 %)
--   - 432 orphelins via old_id → remappables via SIRET partagé
-- ============================================================

ALTER TABLE min.utilisateur DROP CONSTRAINT IF EXISTS utilisateur_structure_id_fkey;

-- Remap ms.id -> sa.id : match direct via old_main_structure_id + fallback
-- (siret, nom) pour les non-winners de vrais doublons exacts. Cf V078 pour
-- la logique détaillée (V073 modifié 2026-05-25 conserve les antennes).
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
UPDATE min.utilisateur u
SET structure_id = mp.new_id
FROM mapping mp
WHERE u.structure_id = mp.old_id;

-- Vérifier 0 orphan
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM min.utilisateur u
  WHERE u.structure_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM main.structure_administrative sa WHERE sa.id = u.structure_id);
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V086 INVARIANT VIOLÉ : % min.utilisateur orphelines', orphans;
  END IF;
END $$;

ALTER TABLE min.utilisateur
  ADD CONSTRAINT utilisateur_structure_id_fkey
  FOREIGN KEY (structure_id)
  REFERENCES main.structure_administrative (id);

DO $$
DECLARE
  total INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM min.utilisateur WHERE structure_id IS NOT NULL;
  RAISE NOTICE 'V086 migrate FK min.utilisateur : OK (% lignes rattachées à une SA)', total;
END $$;
