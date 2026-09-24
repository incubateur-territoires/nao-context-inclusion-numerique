-- ============================================================
-- V080 – Refonte phase 3.a : renommer main.contact_structure → contact_structure_administrative + remap FK
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 1 décision tranchée :
-- 'main.contact_structure (V047) renommé main.contact_structure_administrative
--  en phase 2, FK refkée vers structure_administrative(id). 4 313 lignes
--  préservées.'
--
-- (En pratique : migration en phase 3.a, juste avant la bascule code idposte
--  qui écrit dans cette table.)
--
-- Volume vérifié sur dataspace_dev 2026-05-22 : 5 631 lignes, toutes remappables.
-- (Note : le plan disait 4 313 — augmenté depuis la mesure phase 0)
-- ============================================================

-- 1. Renommer la table
ALTER TABLE main.contact_structure RENAME TO contact_structure_administrative;

-- 2. Renommer la colonne FK pour cohérence sémantique
ALTER TABLE main.contact_structure_administrative
  RENAME COLUMN structure_id TO structure_administrative_id;

-- 3. DROP ancienne FK + contrainte UNIQUE
-- (la contrainte UNIQUE doit être droppée car le remapping par fusion SIRET
--  va créer des doublons temporaires sur (structure_administrative_id, contact_id))
ALTER TABLE main.contact_structure_administrative
  DROP CONSTRAINT IF EXISTS contact_structure_structure_id_fkey;
ALTER TABLE main.contact_structure_administrative
  DROP CONSTRAINT IF EXISTS contact_structure_unique;

-- 4. Remapping structure_administrative_id.
-- Stratégie révisée 2026-05-25 (V073 conserve désormais les antennes via
-- denomination_antenne) : match direct via old_main_structure_id + fallback
-- (siret, nom) pour les non-winners de vrais doublons exacts.
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
UPDATE main.contact_structure_administrative csa
SET structure_administrative_id = m.new_id
FROM mapping m
WHERE csa.structure_administrative_id = m.old_id;

-- 5. Vérifier 0 orphelin
DO $$
DECLARE
  orphans INTEGER;
BEGIN
  SELECT COUNT(*) INTO orphans
  FROM main.contact_structure_administrative csa
  WHERE NOT EXISTS (
    SELECT 1 FROM main.structure_administrative sa WHERE sa.id = csa.structure_administrative_id
  );
  IF orphans > 0 THEN
    RAISE EXCEPTION 'V080 INVARIANT VIOLÉ : % main.contact_structure_administrative orphelins', orphans;
  END IF;
  RAISE NOTICE 'V080 migration FK contact_structure : OK, 0 orphelin';
END $$;

-- 5b. Déduper : la fusion SIRET peut avoir créé des doublons sur
-- (structure_administrative_id, contact_id). On garde la ligne avec le plus petit id.
WITH dedup AS (
  SELECT id, ROW_NUMBER() OVER (
    PARTITION BY structure_administrative_id, contact_id
    ORDER BY id
  ) AS rn
  FROM main.contact_structure_administrative
)
DELETE FROM main.contact_structure_administrative
WHERE id IN (SELECT id FROM dedup WHERE rn > 1);

-- 6. Renommer la PK
ALTER INDEX main.contact_structure_pkey
  RENAME TO contact_structure_administrative_pkey;

-- 7. Recréer la contrainte UNIQUE (droppée en étape 3)
ALTER TABLE main.contact_structure_administrative
  ADD CONSTRAINT contact_structure_administrative_unique
  UNIQUE (structure_administrative_id, contact_id);

-- 8. ADD nouvelle FK vers structure_administrative
ALTER TABLE main.contact_structure_administrative
  ADD CONSTRAINT contact_structure_administrative_structure_id_fkey
  FOREIGN KEY (structure_administrative_id)
  REFERENCES main.structure_administrative (id)
  ON DELETE CASCADE ON UPDATE CASCADE;

-- 9. Renommer les indexes secondaires si présents
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'main' AND indexname = 'contact_structure_structure_id_idx'
  ) THEN
    EXECUTE 'ALTER INDEX main.contact_structure_structure_id_idx
             RENAME TO contact_structure_administrative_structure_id_idx';
  END IF;
END $$;

-- 10. Rapport final
DO $$
DECLARE
  total INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM main.contact_structure_administrative;
  RAISE NOTICE 'V080 rename contact_structure : OK (% lignes après dédup fusion SIRET)', total;
END $$;
