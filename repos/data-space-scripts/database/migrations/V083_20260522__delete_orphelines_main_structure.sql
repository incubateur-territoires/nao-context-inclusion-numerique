-- ============================================================
-- V083 – Phase 0.5.c : suppression des vraies orphelines main.structure
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 0.5.c. Suppression différée jusqu'ici
-- pour ne pas perturber les snapshots des phases 1/2/3. Maintenant que les
-- migrations FK sont stabilisées (V078 poste, V079 contrat, V080 contact,
-- V082 import.carto), on peut faire le ménage.
--
-- CRITÈRE STRICT (cf scripts/audit_orphelines_fk.py) :
--   Une main.structure est orpheline si AUCUNE de ces conditions n'est vraie :
--     - une ligne main.personne_affectations.structure_id pointe dessus (legacy)
--     - une ligne main.activites_coop.structure_id pointe dessus (legacy)
--     - une ligne min.membre.structure_id pointe dessus
--     - une ligne min.utilisateur.structure_id pointe dessus
--     - une structure_administrative l'a en old_main_structure_id (promue)
--     - un lieu_inclusion l'a en old_main_structure_id (promu)
--
-- Mesure dataspace_dev 2026-05-22 :
--   - 16 077 vraies orphelines
--     (carto 11 666 + coop 2 332 + aidants-connect 1 315 + résiduel 764)
--
-- IRRÉVERSIBLE :
--   Le rollback U083 est un noop documenté. Restauration via pg_restore
--   uniquement.
-- ============================================================

DO $$
DECLARE
  before_count INTEGER;
  deleted_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO before_count FROM main.structure;

  WITH deleted AS (
    DELETE FROM main.structure s
    WHERE NOT EXISTS (SELECT 1 FROM main.personne_affectations           WHERE structure_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM main.activites_coop                  WHERE structure_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM min.membre                           WHERE structure_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM min.utilisateur                      WHERE structure_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM main.structure_administrative        WHERE old_main_structure_id = s.id)
      AND NOT EXISTS (SELECT 1 FROM main.lieu_inclusion                  WHERE old_main_structure_id = s.id)
    RETURNING 1
  )
  SELECT COUNT(*) INTO deleted_count FROM deleted;

  RAISE NOTICE 'V083 DELETE orphelines main.structure : % supprimées (avant=% / après=%)',
    deleted_count, before_count, before_count - deleted_count;
END $$;
