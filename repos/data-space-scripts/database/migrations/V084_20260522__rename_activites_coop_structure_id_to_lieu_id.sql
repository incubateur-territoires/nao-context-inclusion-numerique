-- ============================================================
-- V084 – Refonte phase 4c (coop) : rename activites_coop.structure_id → lieu_id
--                                   + FK vers main.lieu_inclusion
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 4c et mémoire métier
-- (project_coop_activite_modele) : main.activites_coop.structure_id pointe
-- sémantiquement sur un LIEU d'accompagnement, jamais une employeuse.
-- Le faux ami "structure" dans le nom doit disparaître.
--
-- Cas où l'info reste utile :
--   1. type_lieu='lieu_activite' → lieu_id valable, FK vers lieu_inclusion
-- Cas où structure_id legacy était une scorie (devient NULL après refonte) :
--   2. type_lieu='autre'   → seule la ville (lieu_code_insee) est l'info
--   3. type_lieu='domicile' → idem
--   4. type_lieu='distance' → fallback sur ville de l'employeuse (lieu_code_insee)
--
-- Le code DAG remplit lieu_id = NULL pour les cas 2/3/4 ; l'info "ville"
-- reste portée par lieu_code_insee + type_lieu (déjà en place).
--
-- Mesures dataspace_dev 2026-05-22 :
--   - 3 812 954 lignes total
--   - 3 703 588 avec structure_id non NULL
--   - 2 612 466 remappables vers lieu_inclusion (70 %)
--   - 1 091 122 orphelines (30 %) → lieu_id = NULL (cas 2/3/4 historiques)
-- ============================================================

-- 1. DROP ancienne FK vers main.structure
ALTER TABLE main.activites_coop
  DROP CONSTRAINT IF EXISTS activites_coop_structure_id_fkey;

-- 2. RENAME colonne pour cohérence sémantique
ALTER TABLE main.activites_coop
  RENAME COLUMN structure_id TO lieu_id;

-- 3. Remap : ancienne valeur main.structure.id → main.lieu_inclusion.id
--    via lieu_inclusion.old_main_structure_id. Les non-matchs deviennent NULL.
WITH mapping AS (
  SELECT li.old_main_structure_id AS old_id, li.id AS new_id
  FROM main.lieu_inclusion li
  WHERE li.old_main_structure_id IS NOT NULL
)
UPDATE main.activites_coop ac
SET lieu_id = m.new_id
FROM mapping m
WHERE ac.lieu_id = m.old_id;

-- 4. Nettoyer les orphelins restants (structure_id pointait sur une
--    employeuse pure, pas un lieu) → lieu_id = NULL.
UPDATE main.activites_coop
SET lieu_id = NULL
WHERE lieu_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion li WHERE li.id = main.activites_coop.lieu_id
  );

-- 5. Vérifier 0 orphelin restant
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM main.activites_coop ac
  WHERE ac.lieu_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM main.lieu_inclusion li WHERE li.id = ac.lieu_id);
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V084 INVARIANT VIOLÉ : % activites_coop orphelines', orphans;
  END IF;
END $$;

-- 6. ADD nouvelle FK vers main.lieu_inclusion (ON DELETE SET NULL pour rester
--    cohérent avec ce qui se passe quand un lieu est supprimé par un merge).
ALTER TABLE main.activites_coop
  ADD CONSTRAINT activites_coop_lieu_id_fkey
  FOREIGN KEY (lieu_id)
  REFERENCES main.lieu_inclusion (id)
  ON DELETE SET NULL;

-- 7. Renommer l'index secondaire s'il existait sous l'ancien nom
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'main' AND indexname = 'activites_coop_structure_id_idx'
  ) THEN
    EXECUTE 'ALTER INDEX main.activites_coop_structure_id_idx
             RENAME TO activites_coop_lieu_id_idx';
  END IF;
END $$;

-- 8. Rapport final
DO $$
DECLARE
  total INTEGER;
  with_lieu INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM main.activites_coop;
  SELECT COUNT(*) INTO with_lieu FROM main.activites_coop WHERE lieu_id IS NOT NULL;
  RAISE NOTICE 'V084 rename activites_coop.structure_id : OK (% lignes total, % rattachées à un lieu)',
    total, with_lieu;
END $$;
