-- ============================================================
-- V089 – Refonte phase 5.3 : api.carto bascule vers lieu_inclusion + SA + paf_*
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 5.3. Vue cartographie publique
-- consommée par postgrest_anct_carto et postgrest_anct_data_incl
-- (carto.gouv.fr + data-inclusion). Critique côté API exposée.
--
-- REFONTE :
--   - Source principale : main.lieu_inclusion (les attributs visible /
--     carto_id / typologies / horaires / services / présentation / contact
--     vivent ici).
--   - SIRET / RNA : récupérés via LEFT JOIN sur l'asso → SA (vérifié 2026-05-22
--     que 0 LI a 2 SA, donc pas de duplication).
--   - personne_affectations_lieu remplace pa.type='lieu_activite'.
--   - personne_affectations_emploi remplace pa.type='structure_emploi'.
--   - CTE courriels lit main.lieu_inclusion.contact (contact JSONB
--     scinder côté LI lors de phase 2 V074).
--
-- COMPTAGES :
--   Legacy 2026-05-22 : 15 168 lignes (post-filtre médiateurs actifs).
--   LI visible + carto_id  : 15 738 (avant filtre médiateurs).
-- ============================================================

DROP VIEW IF EXISTS api.carto;
CREATE VIEW api.carto AS (
  WITH courriels AS (
    SELECT li.id,
           string_agg(
             jsonb_extract_path_text(jsonb_extract_path(li.contact, 'emails'), key.key),
             '|'
           ) AS courriels_concat
    FROM main.lieu_inclusion li,
         LATERAL jsonb_object_keys(jsonb_extract_path(li.contact, 'emails')) key(key)
    GROUP BY li.id
  ),
  personnes AS (
    SELECT sub_table.lieu_id,
           jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
    FROM (
      -- 1) CN seul (= conseiller_numerique_id ou cn_pg_id non NULL, AC absent
      --    sur la même personne, avec une affectation emploi non-AC).
      SELECT pal.lieu_id,
             jsonb_build_object(
               'prenom', p.prenom,
               'nom', p.nom,
               'label',
                 CASE WHEN p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL
                      THEN string_to_array('Conseiller Numerique', ',')
                      ELSE NULL::text[] END,
               'email', COALESCE(
                 (p.contact -> 'coop') ->> 'email',
                 (p.contact -> 'idposte') ->> 'mail_pro',
                 (p.contact -> 'idposte') ->> 'mail_perso'
               ),
               'telephone', COALESCE(
                 (p.contact -> 'coop') ->> 'telephone',
                 (p.contact -> 'idposte') ->> 'telephone'
               )
             ) AS mediateurs
      FROM main.personne_affectations_lieu pal
      JOIN main.personne p ON p.id = pal.personne_id
      WHERE pal.est_active = TRUE
        AND p.is_visible IS DISTINCT FROM FALSE
        AND (
          NOT EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa2
            WHERE pa2.personne_id = p.id
              AND pa2.source = 'aidants-connect'
              AND pa2.est_active = TRUE
          )
          OR p.aidant_connect_id IS NULL
        )
        AND (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
        AND EXISTS (
          SELECT 1 FROM main.personne_affectations_emploi pa_emp
          WHERE pa_emp.personne_id = p.id
            AND pa_emp.est_active = TRUE
            AND pa_emp.source <> 'aidants-connect'
        )

      UNION

      -- 2) AC, ou CN + AC.
      SELECT pal.lieu_id,
             jsonb_build_object(
               'prenom', p.prenom,
               'nom', p.nom,
               'label',
                 CASE WHEN p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL
                      THEN string_to_array('Conseiller Numerique,Aidant Connect', ',')
                      ELSE string_to_array('Aidant Connect', ',') END,
               'email', COALESCE(
                 (p.contact -> 'coop') ->> 'email',
                 (p.contact -> 'idposte') ->> 'mail_pro',
                 (p.contact -> 'idposte') ->> 'mail_perso'
               ),
               'telephone', COALESCE(
                 (p.contact -> 'coop') ->> 'telephone',
                 (p.contact -> 'idposte') ->> 'telephone'
               )
             ) AS mediateurs
      FROM main.personne_affectations_lieu pal
      JOIN main.personne p ON p.id = pal.personne_id
      WHERE pal.est_active = TRUE
        AND p.is_visible IS DISTINCT FROM FALSE
        AND (
          EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa2
            WHERE pa2.personne_id = p.id
              AND pa2.source = 'aidants-connect'
          )
          OR p.aidant_connect_id IS NOT NULL
        )

      UNION

      -- 3) Médiateur numérique simple (ni CN ni AC).
      SELECT pal.lieu_id,
             jsonb_build_object(
               'prenom', p.prenom,
               'nom', p.nom,
               'label', string_to_array('Médiateur numérique', ','),
               'email', COALESCE(
                 (p.contact -> 'coop') ->> 'email',
                 (p.contact -> 'idposte') ->> 'mail_pro',
                 (p.contact -> 'idposte') ->> 'mail_perso'
               ),
               'telephone', COALESCE(
                 (p.contact -> 'coop') ->> 'telephone',
                 (p.contact -> 'idposte') ->> 'telephone'
               )
             ) AS mediateurs
      FROM main.personne_affectations_lieu pal
      JOIN main.personne p ON p.id = pal.personne_id
      WHERE pal.est_active = TRUE
        AND p.is_visible IS DISTINCT FROM FALSE
        AND p.is_mediateur = TRUE
        AND p.conseiller_numerique_id IS NULL
        AND p.cn_pg_id IS NULL
        AND p.aidant_connect_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM main.personne_affectations_emploi pa2
          WHERE pa2.personne_id = p.id
            AND pa2.source = 'aidants-connect'
        )
    ) sub_table
    GROUP BY sub_table.lieu_id
  )
  SELECT
    li.structure_cartographie_nationale_id AS id,
    COALESCE(sa.siret, sa.rna, '00000000000000')::character varying(14) AS pivot,
    li.nom,
    jsonb_build_object(
      'numero_voie', a.numero_voie,
      'repetition', a.repetition,
      'nom_voie', a.nom_voie,
      'code_postal', a.code_postal,
      'commune', a.nom_commune,
      'code_insee', a.code_insee
    ) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    li.typologies AS typologie,
    jsonb_extract_path_text(li.contact, 'telephone') AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(li.contact, 'site_web') AS site_web,
    li.horaires,
    li.presentation_resume,
    li.presentation_detail,
    li.source,
    li.itinerance,
    COALESCE(li.updated_at, li.created_at) AS date_maj,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.prise_rdv,
    personnes.mediateurs
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse a ON a.id = li.adresse_id
  LEFT JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
  LEFT JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
  LEFT JOIN courriels ON courriels.id = li.id
  LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    AND li.visible_pour_cartographie_nationale = TRUE
    AND (
      NOT EXISTS (
        SELECT 1 FROM main.personne_affectations_lieu pal
        WHERE pal.lieu_id = li.id AND pal.est_active = TRUE
      )
      OR EXISTS (
        SELECT 1 FROM main.personne_affectations_lieu pal_lieu
        JOIN main.personne_affectations_emploi pa_emploi
          ON pa_emploi.personne_id = pal_lieu.personne_id
          AND pa_emploi.est_active = TRUE
          AND pa_emploi.source <> 'aidants-connect'
        WHERE pal_lieu.lieu_id = li.id AND pal_lieu.est_active = TRUE
      )
    )
);

COMMENT ON VIEW api.carto IS
  'Vue cartographie publique refondue phase 5.3 (V089). Source : '
  'main.lieu_inclusion + asso vers structure_administrative pour SIRET/RNA. '
  'Médiateurs : personne_affectations_lieu (lien personne ↔ lieu), filtre '
  'emploi non-AC via personne_affectations_emploi.';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

NOTIFY pgrst, 'reload schema';
