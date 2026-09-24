-- ============================================================
-- V088 – Refonte phase 5.2 : api.aidants_connect bascule vers SA + LI
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 5.2. La vue legacy résout la
-- structure employeuse d'un aidant via main.personne_affectations en
-- priorisant pa.type='structure_emploi' puis 'lieu_activite' en fallback.
--
-- Refonte : on remplace par UNION ALL de
--   - main.personne_affectations_emploi → structure_administrative (priorité 0)
--   - main.personne_affectations_lieu   → lieu_inclusion (priorité 1, fallback)
-- DISTINCT ON (personne_id) garde la 1ère ligne après tri par priorité.
--
-- COMPORTEMENT :
--   - structure_employeuse.id : devient SA.id (cas emploi) ou LI.id (fallback).
--     Sémantiquement plus précis qu'avant — un consommateur qui s'appuyait sur
--     l'id legacy main.structure.id ne le retrouvera pas. Voir docs/N6.
--   - nom : pour les SA avec asso, on prend LI.nom (plus humain) ; sinon
--     SA.denomination_sirene.
--   - Consommateur connu : postgrest_anct_incub (ANCT Incub).
--
-- Comptages dataspace_dev 2026-05-22 (legacy) :
--   - 18 368 aidants total, 12 337 avec employeuse, 6 031 sans.
-- ============================================================

DROP VIEW IF EXISTS api.aidants_connect;
CREATE VIEW api.aidants_connect AS (
  WITH employeurs AS (
    SELECT DISTINCT ON (personne_id)
      personne_id,
      structure_id,
      nom,
      adresse,
      code_insee,
      commune,
      code_departement
    FROM (
      -- 1) Emploi prioritaire : SA
      --    nom = LI.nom (mixte avec asso) sinon denomination_sirene.
      SELECT
        pae.personne_id,
        sa.id AS structure_id,
        COALESCE(li.nom, sa.denomination_sirene) AS nom,
        concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
        a.code_insee,
        a.nom_commune AS commune,
        a.departement AS code_departement,
        0 AS priority,
        COALESCE(pae.updated_at, pae.created_at) AS ts,
        pae.id AS aff_id
      FROM main.personne_affectations_emploi pae
      JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
      LEFT JOIN main.lieu_inclusion_structure_administrative asso
        ON asso.structure_administrative_id = sa.id
      LEFT JOIN main.lieu_inclusion li ON li.id = asso.lieu_id
      LEFT JOIN main.adresse a ON a.id = COALESCE(li.adresse_id, sa.adresse_id)
      WHERE pae.est_active = TRUE

      UNION ALL

      -- 2) Lieu d'activité en fallback : LI
      SELECT
        pal.personne_id,
        li.id AS structure_id,
        li.nom,
        concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
        a.code_insee,
        a.nom_commune AS commune,
        a.departement AS code_departement,
        1 AS priority,
        COALESCE(pal.updated_at, pal.created_at) AS ts,
        pal.id AS aff_id
      FROM main.personne_affectations_lieu pal
      JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
      LEFT JOIN main.adresse a ON a.id = li.adresse_id
      WHERE pal.est_active = TRUE
    ) candidates
    ORDER BY personne_id, priority, ts DESC, aff_id DESC
  )
  SELECT
    p.aidant_connect_id,
    p.id,
    COALESCE(p.nb_accompagnements_ac, 0) AS nb_accompagnements,
    e.code_insee,
    jsonb_strip_nulls(jsonb_build_object(
      'id', e.structure_id,
      'nom', e.nom,
      'adresse', e.adresse,
      'code_insee', e.code_insee,
      'commune', e.commune,
      'departement', e.code_departement
    )) AS structure_employeuse
  FROM main.personne p
  LEFT JOIN employeurs e ON e.personne_id = p.id
  WHERE p.aidant_connect_id IS NOT NULL
);

COMMENT ON VIEW api.aidants_connect IS
  'Vue de compat refondue phase 5.2 (V088). Résout la structure employeuse '
  'd''un aidant via personne_affectations_emploi (SA) en priorité, fallback '
  'sur personne_affectations_lieu (LI). structure_employeuse.id : SA.id ou '
  'LI.id selon le cas, plus main.structure.id legacy. À sonder côté '
  'postgrest_anct_incub avant DROP main.structure (cf docs/N6).';

GRANT SELECT ON TABLE api.aidants_connect TO postgrest_anct_incub;

NOTIFY pgrst, 'reload schema';
