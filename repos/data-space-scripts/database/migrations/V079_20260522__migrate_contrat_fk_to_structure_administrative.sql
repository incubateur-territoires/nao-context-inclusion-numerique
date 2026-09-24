-- ============================================================
-- V079 – Refonte phase 3.a : migrer main.contrat.structure_id → structure_administrative
-- ============================================================
-- Même pattern que V078. Volume : 6 187 lignes main.contrat, toutes avec
-- structure_id renseigné.
-- ============================================================

ALTER TABLE main.contrat DROP CONSTRAINT IF EXISTS contrat_structure_id_fkey;

-- Remapping ms.id -> sa.id (cf V078 pour la logique). Match direct via
-- old_main_structure_id + fallback (siret, nom) pour les non-winners de
-- vrais doublons.
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
UPDATE main.contrat c
SET structure_id = m.new_id
FROM mapping m
WHERE c.structure_id = m.old_id;

-- Vérification
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM main.contrat c
  WHERE c.structure_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM main.structure_administrative sa WHERE sa.id = c.structure_id
    );
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V079 INVARIANT VIOLÉ : % main.contrat.structure_id pendants', orphans;
  END IF;
  RAISE NOTICE 'V079 migration FK main.contrat : OK, 0 orphelin';
END $$;

ALTER TABLE main.contrat
  ADD CONSTRAINT contrat_structure_id_fkey
  FOREIGN KEY (structure_id) REFERENCES main.structure_administrative (id);
