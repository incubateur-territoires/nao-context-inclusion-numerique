-- ============================================================
-- V075 – Refonte phase 2 : peuplement de l'asso lieu ⋈ admin
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 2. Stratégie conservatrice
-- (décision 2026-05-22) : on crée l'asso UNIQUEMENT pour les "mixtes" =
-- une même ligne main.structure qui était à la fois côté employeuse ET
-- côté lieu. On NE crée PAS d'asso "par SIRET partagé" pour éviter de
-- propager la dette de qualité des SIRETs carto (= SIRET du porteur, pas
-- du lieu lui-même).
--
-- Les asso bonus (cas type La Poste sur 33 antennes, Loir-et-Cher pattern)
-- seront créées par les DAGs refondus en phase 4 (notamment carto-dag-import).
--
-- Volume attendu : 3 614 mixtes → 3 614 asso
-- ============================================================

INSERT INTO main.lieu_inclusion_structure_administrative (
  lieu_id, structure_administrative_id, edited_by, created_at
)
SELECT
  lieu.id AS lieu_id,
  admin.id AS structure_administrative_id,
  COALESCE(admin.edited_by, lieu.edited_by) AS edited_by,
  GREATEST(admin.created_at, lieu.created_at) AS created_at
FROM main.lieu_inclusion lieu
JOIN main.structure_administrative admin
  -- Asso 1:1 par old_main_structure_id : un mixte a écrit lieu.old = admin.old
  ON admin.old_main_structure_id = lieu.old_main_structure_id;

-- Vérification post-INSERT
DO $$
DECLARE
  total INTEGER;
  attendu INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM main.lieu_inclusion_structure_administrative;
  -- Mixtes attendus : structures qui sont à la fois is_admin ET is_lieu
  SELECT COUNT(*) INTO attendu
  FROM main.structure s
  WHERE (
    EXISTS (SELECT 1 FROM main.personne_affectations pa
            WHERE pa.structure_id = s.id AND pa.type = 'structure_emploi')
    OR EXISTS (SELECT 1 FROM main.contrat            WHERE structure_id = s.id)
    OR EXISTS (SELECT 1 FROM main.poste              WHERE structure_id = s.id)
    OR EXISTS (SELECT 1 FROM main.contact_structure  WHERE structure_id = s.id)
    OR EXISTS (SELECT 1 FROM min.membre              WHERE structure_id = s.id)
    OR EXISTS (SELECT 1 FROM min.utilisateur         WHERE structure_id = s.id)
  )
  AND (
    s.structure_cartographie_nationale_id IS NOT NULL
    OR EXISTS (SELECT 1 FROM main.personne_affectations pa
               WHERE pa.structure_id = s.id AND pa.type = 'lieu_activite')
  );
  RAISE NOTICE 'V075 peuplement asso lieu ⋈ admin : total=%, mixtes_attendus=%', total, attendu;
  -- Note : total <= attendu car les "admin" gagnants par fusion SIRET sont uniques
  -- mais les "mixtes" peuvent être absorbés par fusion. Si total < attendu, les
  -- mixtes absorbés perdent leur asso 1:1 (on les retrouvera plus tard via SIRET).
END $$;
