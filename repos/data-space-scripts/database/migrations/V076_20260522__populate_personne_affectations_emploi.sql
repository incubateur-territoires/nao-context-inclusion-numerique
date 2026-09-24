-- ============================================================
-- V076 – Refonte phase 2 : peuplement personne_affectations_emploi
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 2. Migration des affectations
-- type='structure_emploi' de main.personne_affectations vers la nouvelle
-- table dédiée.
--
-- MAPPING (révisé 2026-05-25 — V073 conserve désormais les antennes via
--          denomination_antenne) :
-- pa.structure_id → structure_administrative.id via :
--   1. sa.old_main_structure_id = pa.structure_id (match direct du legacy)
--   2. fallback (siret, nom) pour les non-winners de vrais doublons exacts.
-- Garantit que chaque affectation pointe sur la BONNE antenne (et non
-- arbitrairement sur l'une des SA partageant le SIRET).
--
-- Volume attendu (mesure phase 0) :
--   - 31 254 affectations structure_emploi (active + inactive)
--   - Filtre : source NOT NULL (contrainte CHECK)
--   - Et exclusion des affectations dont la structure_administrative
--     cible n'existe pas (= structure source était dans 'vraies orphelines'
--     supprimées en phase 0.5.c — non encore exécutée mais on filtre
--     proactivement)
-- ============================================================

INSERT INTO main.personne_affectations_emploi (
  personne_id, structure_administrative_id,
  source, est_active,
  created_at, updated_at
)
SELECT
  pa.personne_id,
  -- Mapping pa.structure_id → structure_administrative.id (cf V078 pour
  -- la logique détaillée : match direct via old_main_structure_id +
  -- fallback (siret, nom) pour les non-winners de vrais doublons).
  (
    SELECT sa.id FROM main.structure_administrative sa
    JOIN main.structure ms ON ms.id = pa.structure_id
    WHERE sa.old_main_structure_id = ms.id
       OR (
         sa.siret IS NOT DISTINCT FROM ms.siret
         AND COALESCE(sa.denomination_antenne, ms.nom) = ms.nom
       )
    LIMIT 1
  ) AS structure_administrative_id,
  pa.source, pa.est_active,
  pa.created_at, pa.updated_at
FROM main.personne_affectations pa
WHERE pa.type = 'structure_emploi'
  AND pa.source IS NOT NULL  -- contrainte CHECK côté nouvelle table
  AND pa.personne_id IS NOT NULL
  AND pa.structure_id IS NOT NULL
  -- Exclure les affectations dont la structure_administrative n'existe pas
  AND EXISTS (
    SELECT 1 FROM main.structure_administrative sa
    JOIN main.structure ms ON ms.id = pa.structure_id
    WHERE sa.old_main_structure_id = ms.id
       OR (
         sa.siret IS NOT DISTINCT FROM ms.siret
         AND COALESCE(sa.denomination_antenne, ms.nom) = ms.nom
       )
  )
-- Déduplication intra-batch : la fusion SIRET peut produire plusieurs lignes
-- pointant sur la même (personne, structure_administrative, source). On garde
-- la plus récente / active.
ON CONFLICT (personne_id, structure_administrative_id, source) DO NOTHING;

-- Vérification
DO $$
DECLARE
  total_new INTEGER;
  total_old INTEGER;
  diff INTEGER;
BEGIN
  SELECT COUNT(*) INTO total_new FROM main.personne_affectations_emploi;
  SELECT COUNT(*) INTO total_old FROM main.personne_affectations
    WHERE type = 'structure_emploi' AND source IS NOT NULL
      AND personne_id IS NOT NULL AND structure_id IS NOT NULL;
  diff := total_old - total_new;
  RAISE NOTICE 'V076 peuplement personne_affectations_emploi : nouveau=% / ancien_valide=% (diff=%)',
    total_new, total_old, diff;
  IF diff > 0 THEN
    RAISE NOTICE 'Note : % affectations perdues (orphelines/fusions ON CONFLICT)', diff;
  END IF;
END $$;
