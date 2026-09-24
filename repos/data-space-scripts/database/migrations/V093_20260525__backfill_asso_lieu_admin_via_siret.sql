-- ============================================================
-- V093 – Refonte phase 5.5 : backfill asso lieu ⋈ admin via SIRET partagé
-- ============================================================
-- CONTEXTE :
-- Filet de sécurité pour les lieu_inclusion qui n'ont AUCUNE asso après V075
-- (cas exotiques : lieu pur-lieu sans pendant admin par old_main_structure_id).
--
-- Avec V073 modifié 2026-05-25 (conservation des antennes via
-- denomination_antenne), V075 couvre désormais la quasi-totalité des cas
-- 1:1 (chaque legacy main.structure avec un nom devient sa propre SA, donc
-- lieu.old_main_structure_id matche admin.old_main_structure_id direct).
-- V093 ne devrait créer que quelques asso résiduelles.
--
-- STRATÉGIE :
-- Pour chaque lieu sans asso, on crée UNE seule asso vers la SA "la plus
-- pertinente" partageant le SIRET du legacy lieu :
--   - en priorité : SA sans denomination_antenne (= entité unique pour ce SIRET)
--   - sinon : SA avec le plus petit id (stable)
-- Idempotent via NOT EXISTS.
-- ============================================================

INSERT INTO main.lieu_inclusion_structure_administrative (
  lieu_id, structure_administrative_id, edited_by, created_at
)
SELECT DISTINCT ON (l.id)
  l.id AS lieu_id,
  sa.id AS structure_administrative_id,
  'V093_siret_bridge' AS edited_by,
  now() AS created_at
FROM main.lieu_inclusion l
JOIN main.structure ms_lieu ON ms_lieu.id = l.old_main_structure_id
JOIN main.structure_administrative sa ON sa.siret = ms_lieu.siret
WHERE ms_lieu.siret IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.lieu_id = l.id
  )
ORDER BY l.id, (sa.denomination_antenne IS NOT NULL), sa.id;

-- Vérification + rapport
DO $$
DECLARE
  nb_inserees INTEGER;
  total_asso INTEGER;
  lieux_orphelins_restants INTEGER;
BEGIN
  GET DIAGNOSTICS nb_inserees = ROW_COUNT;
  SELECT COUNT(*) INTO total_asso FROM main.lieu_inclusion_structure_administrative;

  -- Vérifier qu'il ne reste plus de lieux SANS aucune asso pour lesquels une
  -- SA partage leur SIRET legacy (= le lieu avait un rattachement potentiel
  -- via SIRET mais n'a aucune asso). Avec V073 modifié, ce nombre devrait être
  -- 0 car V075 couvre la quasi-totalité des cas.
  SELECT COUNT(*) INTO lieux_orphelins_restants
  FROM main.lieu_inclusion l
  WHERE EXISTS (
      SELECT 1 FROM main.structure ms_lieu
      JOIN main.structure_administrative sa ON sa.siret = ms_lieu.siret
      WHERE ms_lieu.id = l.old_main_structure_id
        AND ms_lieu.siret IS NOT NULL
    )
    AND NOT EXISTS (
      SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
      WHERE asso.lieu_id = l.id
    );

  RAISE NOTICE 'V093 backfill asso via SIRET : % nouvelles asso créées (total asso = %, lieux sans aucune asso = %)',
    nb_inserees, total_asso, lieux_orphelins_restants;

  IF lieux_orphelins_restants > 0 THEN
    RAISE EXCEPTION 'V093 INVARIANT VIOLÉ : % lieux restent sans aucune asso bien qu''un SIRET commun avec une SA existe', lieux_orphelins_restants;
  END IF;
END $$;
