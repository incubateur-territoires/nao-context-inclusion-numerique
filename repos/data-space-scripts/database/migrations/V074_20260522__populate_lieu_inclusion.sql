-- ============================================================
-- V074 – Refonte phase 2 : peuplement initial de lieu_inclusion
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 2. main.structure → lieu_inclusion
-- pour les lignes côté lieu. 1:1 (pas de fusion) — chaque main.structure
-- 'is_lieu' donne 1 lieu_inclusion distinct.
--
-- CRITÈRE 'is_lieu' (cf décision tranchée 2026-05-22, corrigé activites_coop) :
--   - a une affectation type=lieu_activite (active OU inactive), OU
--   - a un structure_cartographie_nationale_id
-- (activites_coop pointe sur structure_employeuse via structure_id, pas sur
--  le lieu — le lieu est dans lieu_code_insee. Donc PAS dans is_lieu.)
--
-- RÈGLE JSONB CONTACT (cf décisions tranchées) :
--   On ne garde que les clés génériques publiques du lieu :
--   telephone, courriels, site_web. Les clés nom/prenom (référent nommé)
--   restent côté structure_administrative.
--
-- Volume attendu (cf mesure 2026-05-22) :
--   - 17 302 pures lieux + 3 614 mixtes = 20 916 lignes
-- ============================================================

WITH s_kinds AS (
  SELECT
    s.id,
    (
      s.structure_cartographie_nationale_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM main.personne_affectations pa
                 WHERE pa.structure_id = s.id AND pa.type = 'lieu_activite')
    ) AS is_lieu
  FROM main.structure s
)
INSERT INTO main.lieu_inclusion (
  old_main_structure_id,
  nom, adresse_id,
  structure_cartographie_nationale_id, visible_pour_cartographie_nationale, fiche_acces_libre,
  presentation_resume, presentation_detail,
  horaires, prise_rdv, itinerance,
  services, modalites_acces, modalites_accompagnement,
  publics_specifiquement_adresses, prise_en_charge_specifique, frais_a_charge,
  formations_labels, autres_formations_labels, dispositif_programmes_nationaux,
  typologies,
  contact,
  mediateurs_en_activite, emplois,
  source, edited_by,
  created_at, updated_at
)
SELECT
  s.id AS old_main_structure_id,
  s.nom, s.adresse_id,
  s.structure_cartographie_nationale_id, s.visible_pour_cartographie_nationale, s.fiche_acces_libre,
  s.presentation_resume, s.presentation_detail,
  s.horaires, s.prise_rdv, s.itinerance,
  s.services, s.modalites_acces, s.modalites_accompagnement,
  s.publics_specifiquement_adresses, s.prise_en_charge_specifique, s.frais_a_charge,
  s.formations_labels, s.autres_formations_labels, s.dispositif_programmes_nationaux,
  s.typologies,
  -- Scission du JSONB : on ne garde que telephone, courriels, site_web pour le lieu.
  -- Les clés nom/prenom (référent nommé) restent côté structure_administrative.
  CASE
    WHEN s.contact IS NULL THEN NULL
    ELSE jsonb_strip_nulls(jsonb_build_object(
      'telephone', s.contact->'telephone',
      'courriels', s.contact->'courriels',
      'site_web',  s.contact->'site_web'
    ))
  END AS contact,
  s.mediateurs_en_activite, s.emplois,
  s.source, s.edited_by,
  s.created_at, s.updated_at
FROM main.structure s
JOIN s_kinds sk ON sk.id = s.id
WHERE sk.is_lieu;

-- Avancer la sequence
SELECT setval(
  pg_get_serial_sequence('main.lieu_inclusion', 'id'),
  COALESCE((SELECT MAX(id) FROM main.lieu_inclusion), 1)
);

-- Vérification post-INSERT
DO $$
DECLARE
  total INTEGER;
  avec_carto INTEGER;
  visibles INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM main.lieu_inclusion;
  SELECT COUNT(*) INTO avec_carto FROM main.lieu_inclusion
    WHERE structure_cartographie_nationale_id IS NOT NULL;
  SELECT COUNT(*) INTO visibles FROM main.lieu_inclusion
    WHERE visible_pour_cartographie_nationale = TRUE;
  RAISE NOTICE 'V074 peuplement lieu_inclusion : total=% (avec_carto_id=%, visibles=%)',
    total, avec_carto, visibles;
END $$;
