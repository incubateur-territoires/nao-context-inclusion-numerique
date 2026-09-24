-- ============================================================
-- V092 – Refonte phase 5.4 : min.personne_enrichie via paf_emploi
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 5.4. Vue MIN consommée par Prisma
-- (PrismaStructuresEmployeusesCoopLoader / min.postes_conseiller_numerique_synthese).
-- À refondre conjointement avec l'équipe MIN — cf docs N6.
--
-- BASCULE :
--   - main.personne_affectations (type='structure_emploi') → main.personne_affectations_emploi
--     (table dédiée, type implicite)
--   - pa.structure_id → paf_emploi.structure_administrative_id
--
-- COMPORTEMENT :
--   - structure_employeuse_id : devient structure_administrative.id au lieu de
--     main.structure.id legacy. Si MIN utilise cet ID pour des JOIN, vérifier
--     que la table cible accepte SA.id (par ex. via la FK déjà migrée en V085).
--   - Les autres colonnes (labellisation_aidant_connect, est_actuellement_*)
--     gardent leur sémantique.
--
-- Comptages legacy 2026-05-22 : 24 896 personnes, 12 120 labellisées AC,
--   3 987 médiateurs actifs, 15 601 avec une structure_employeuse_id.
-- ============================================================

DROP VIEW IF EXISTS min.personne_enrichie;
CREATE VIEW min.personne_enrichie AS (
  WITH personne_avec_status AS (
    SELECT p.id,
           p.prenom,
           p.nom,
           p.contact,
           p.aidant_connect_id,
           p.conseiller_numerique_id,
           p.cn_pg_id,
           p.coop_id,
           p.is_coordinateur,
           p.is_mediateur,
           p.formation_fne_ac,
           p.profession_ac,
           p.nb_accompagnements_ac,
           p.created_at,
           p.updated_at,
           p.edited_by,
           p.deleted_at,
           p.deleted_by,
           CASE
             WHEN p.is_mediateur = TRUE THEN 'mediateur'::text
             WHEN p.is_mediateur = FALSE OR p.is_mediateur IS NULL THEN 'aidant_numerique'::text
             ELSE NULL::text
           END AS type_accompagnateur,
           EXISTS (
             SELECT 1 FROM main.personne_affectations_emploi pae
             WHERE pae.personne_id = p.id
               AND pae.source = 'aidants-connect'
               AND pae.est_active = TRUE
           ) AS labellisation_aidant_connect,
           CASE
             WHEN p.is_mediateur = TRUE
                  AND EXISTS (
                    SELECT 1 FROM main.personne_affectations_emploi pae
                    WHERE pae.personne_id = p.id
                      AND pae.est_active = TRUE
                      AND pae.source IN ('idposte', 'coop')
                  ) THEN TRUE
             ELSE FALSE
           END AS est_actuellement_mediateur_en_poste,
           CASE
             WHEN (p.is_mediateur = FALSE OR p.is_mediateur IS NULL)
                  AND EXISTS (
                    SELECT 1 FROM main.personne_affectations_emploi pae
                    WHERE pae.personne_id = p.id
                      AND pae.source = 'aidants-connect'
                      AND pae.est_active = TRUE
                  ) THEN TRUE
             ELSE FALSE
           END AS est_actuellement_aidant_numerique_en_poste
    FROM main.personne p
  )
  SELECT id,
         prenom,
         nom,
         contact,
         aidant_connect_id,
         conseiller_numerique_id,
         cn_pg_id,
         coop_id,
         is_coordinateur,
         is_mediateur,
         formation_fne_ac,
         profession_ac,
         nb_accompagnements_ac,
         created_at,
         updated_at,
         edited_by,
         deleted_at,
         deleted_by,
         type_accompagnateur,
         labellisation_aidant_connect,
         est_actuellement_mediateur_en_poste,
         est_actuellement_aidant_numerique_en_poste,
         CASE
           WHEN EXISTS (
             SELECT 1 FROM main.personne_affectations_emploi pae
             WHERE pae.personne_id = personne_avec_status.id
               AND pae.source = 'idposte'
               AND pae.est_active = TRUE
           ) THEN TRUE
           ELSE FALSE
         END AS est_actuellement_conseiller_numerique,
         CASE
           WHEN is_coordinateur = TRUE
                AND (est_actuellement_mediateur_en_poste = TRUE
                     OR est_actuellement_aidant_numerique_en_poste = TRUE)
             THEN TRUE
           ELSE FALSE
         END AS est_actuellement_coordo_actif,
         (SELECT pae.structure_administrative_id
          FROM main.personne_affectations_emploi pae
          WHERE pae.personne_id = personne_avec_status.id
            AND pae.est_active = TRUE
          ORDER BY pae.structure_administrative_id
          LIMIT 1) AS structure_employeuse_id
  FROM personne_avec_status
);

COMMENT ON VIEW min.personne_enrichie IS
  'Vue MIN refondue phase 5.4 (V092). structure_employeuse_id pointe désormais '
  'sur main.structure_administrative.id (au lieu de main.structure.id legacy). '
  'Cohérent avec la migration FK V085 (min.membre) et V086 (min.utilisateur).';

GRANT SELECT ON TABLE min.personne_enrichie TO sonum;
GRANT SELECT ON TABLE min.personne_enrichie TO app_python;
GRANT SELECT ON TABLE min.personne_enrichie TO min_scalingo;
GRANT SELECT ON TABLE min.personne_enrichie TO min_dev;
