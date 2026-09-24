-- ============================================================
-- V081 – Refonte phase 4 (carto) : ajout structure_coop_id + import_warnings
--                                   sur main.lieu_inclusion
-- ============================================================
-- CONTEXTE :
-- Le DAG carto-dag-import alimente uniquement des lieux d'inclusion (pas de
-- structure_administrative). Aujourd'hui sur main.structure (legacy), le
-- structure_coop_id est porté à la fois côté employeur ET côté lieu — on
-- garde cette dualité dans le nouveau modèle :
--   - main.structure_administrative.structure_coop_id : déjà présent (V068)
--   - main.lieu_inclusion.structure_coop_id           : ajouté ici
--
-- Décision tranchée (phase 4 carto) :
--   "on doit avoir structure_coop_id dans les structures administratives ET
--    les lieux d'inclusion. Si carto injecte un nouveau lieu avec un coop_id
--    inconnu en base, on l'injecte quand même et on log un warn JSON."
--
-- Mesures dataspace_dev 2026-05-22 :
--   - 19 509 LI avec old_main_structure_id
--   - 11 486 LI dont l'ancienne main.structure avait un coop_id (≈ 59 %)
--   - 0 doublon (UNIQUE compatible)
-- ============================================================

-- 1. ADD COLUMN structure_coop_id (UUID, UNIQUE NULL accepté)
ALTER TABLE main.lieu_inclusion
  ADD COLUMN IF NOT EXISTS structure_coop_id UUID;

-- 2. ADD COLUMN import_warnings (JSONB, accumule des messages de log d'import)
--    Pattern attendu : { "carto_2026-05-22T..": { "level": "warn", "code": "unknown_coop_id", "message": "..." }, ... }
ALTER TABLE main.lieu_inclusion
  ADD COLUMN IF NOT EXISTS import_warnings JSONB;

-- 3. Backfill structure_coop_id depuis main.structure (legacy) via old_main_structure_id
UPDATE main.lieu_inclusion li
SET structure_coop_id = ms.structure_coop_id
FROM main.structure ms
WHERE ms.id = li.old_main_structure_id
  AND ms.structure_coop_id IS NOT NULL
  AND li.structure_coop_id IS NULL;

-- 4. Vérifier 0 doublon avant de poser la contrainte UNIQUE
DO $$
DECLARE
  doublons INTEGER;
BEGIN
  SELECT COUNT(*) INTO doublons
  FROM (
    SELECT structure_coop_id FROM main.lieu_inclusion
    WHERE structure_coop_id IS NOT NULL
    GROUP BY structure_coop_id HAVING COUNT(*) > 1
  ) d;
  IF doublons > 0 THEN
    RAISE EXCEPTION 'V081 INVARIANT VIOLÉ : % structure_coop_id en doublon sur main.lieu_inclusion', doublons;
  END IF;
  RAISE NOTICE 'V081 backfill structure_coop_id : OK, 0 doublon';
END $$;

-- 5. ADD UNIQUE CONSTRAINT (NULL multiples acceptés)
ALTER TABLE main.lieu_inclusion
  ADD CONSTRAINT lieu_inclusion_structure_coop_id_ukey UNIQUE (structure_coop_id);

-- 6. Rapport final
DO $$
DECLARE
  total_li INTEGER;
  with_coop_id INTEGER;
BEGIN
  SELECT COUNT(*) INTO total_li FROM main.lieu_inclusion;
  SELECT COUNT(*) INTO with_coop_id FROM main.lieu_inclusion WHERE structure_coop_id IS NOT NULL;
  RAISE NOTICE 'V081 ADD coop_id + warnings : OK (% lieux total, % avec coop_id backfillé)', total_li, with_coop_id;
END $$;
