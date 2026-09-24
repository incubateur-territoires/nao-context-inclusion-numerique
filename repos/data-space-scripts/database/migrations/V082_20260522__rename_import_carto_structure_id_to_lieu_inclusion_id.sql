-- ============================================================
-- V082 – Refonte phase 4 (carto) : rename import.carto.structure_id → lieu_inclusion_id
--                                   + remap FK vers main.lieu_inclusion
-- ============================================================
-- CONTEXTE :
-- Avant la refonte, import.carto.structure_id pointait sur main.structure(id)
-- avec ON DELETE SET NULL — c'était le backfill alimenté en fin de DAG
-- (cf carto-dag-import.py, étape "Backfill : relier chaque ligne import.carto
-- à la structure correspondante").
--
-- Dans le nouveau modèle, le DAG carto alimente exclusivement
-- main.lieu_inclusion (décision tranchée phase 4 carto : "carto n'importe que
-- des lieux d'inclusion"). On bascule donc la FK de import.carto vers
-- main.lieu_inclusion(id).
--
-- Stratégie de remap :
--   import.carto.structure_id (legacy main.structure.id)
--     → main.lieu_inclusion.id via main.lieu_inclusion.old_main_structure_id
--
-- Mesures dataspace_dev 2026-05-22 :
--   - 15 744 lignes import.carto
--   - 15 411 lignes avec structure_id non NULL → 100 % remappables
--   - 0 orphan
-- ============================================================

-- 1. DROP ancienne FK vers main.structure
ALTER TABLE import.carto
  DROP CONSTRAINT IF EXISTS carto_structure_id_fkey;

-- 2. RENAME colonne pour cohérence sémantique
ALTER TABLE import.carto
  RENAME COLUMN structure_id TO lieu_inclusion_id;

-- 3. Remap : ancienne valeur main.structure.id → nouvelle main.lieu_inclusion.id
WITH mapping AS (
  SELECT li.old_main_structure_id AS old_id, li.id AS new_id
  FROM main.lieu_inclusion li
  WHERE li.old_main_structure_id IS NOT NULL
)
UPDATE import.carto c
SET lieu_inclusion_id = m.new_id
FROM mapping m
WHERE c.lieu_inclusion_id = m.old_id;

-- 4. Vérifier 0 orphan (lignes qui n'ont pas trouvé de lieu correspondant)
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM import.carto c
  WHERE c.lieu_inclusion_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM main.lieu_inclusion li WHERE li.id = c.lieu_inclusion_id
    );
  IF orphans > 0 THEN
    -- On vide les orphans en NULL plutôt que de RAISE EXCEPTION : la FK
    -- d'origine avait ON DELETE SET NULL, on conserve la même tolérance.
    UPDATE import.carto SET lieu_inclusion_id = NULL
    WHERE lieu_inclusion_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM main.lieu_inclusion li WHERE li.id = import.carto.lieu_inclusion_id
      );
    RAISE NOTICE 'V082 remap : % lignes import.carto orphelines mises à NULL', orphans;
  END IF;
END $$;

-- 5. ADD nouvelle FK vers main.lieu_inclusion (ON DELETE SET NULL, comme l'ancienne)
ALTER TABLE import.carto
  ADD CONSTRAINT carto_lieu_inclusion_id_fkey
  FOREIGN KEY (lieu_inclusion_id)
  REFERENCES main.lieu_inclusion (id)
  ON DELETE SET NULL;

-- 6. Index pour le lookup inverse (lieu → lignes import.carto)
CREATE INDEX IF NOT EXISTS carto_lieu_inclusion_id_idx
  ON import.carto (lieu_inclusion_id)
  WHERE lieu_inclusion_id IS NOT NULL;

-- 7. Rapport final
DO $$
DECLARE
  total INTEGER;
  with_li INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM import.carto;
  SELECT COUNT(*) INTO with_li FROM import.carto WHERE lieu_inclusion_id IS NOT NULL;
  RAISE NOTICE 'V082 rename import.carto.structure_id : OK (% lignes, % rattachées à un lieu)', total, with_li;
END $$;
