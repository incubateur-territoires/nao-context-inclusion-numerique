-- ============================================================
-- V105 – api.carto : garder les lieux dont tous les médiateurs sont inactifs
-- ============================================================
-- CONTEXTE (issue SEPT #1348) :
-- Lors de la refonte, une règle avait été posée (V061, maintenue jusqu'à V101)
-- pour ne PAS exposer un lieu dont tous les conseillers numériques / médiateurs
-- rattachés ont des contrats inactifs (aucune affectation emploi non-AC active).
-- Décision métier : revenir sur cette règle. On continue d'afficher le lieu même
-- si plus aucun médiateur n'est actif dessus.
--
-- CHANGEMENT :
--   - Suppression du dernier bloc du WHERE de api.carto :
--       AND ( NOT EXISTS (... pal active ...) OR EXISTS (... emploi non-AC actif ...) )
--   - Le reste de la vue (CTE courriels / personnes, SELECT, JOINs) est
--     STRICTEMENT identique à V101.
--   - Le filtre par-personne (tableau `mediateurs`) reste inchangé : un lieu sans
--     médiateur actif paraît désormais, simplement avec mediateurs = NULL.
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
    SELECT sub.lieu_id,
           jsonb_strip_nulls(jsonb_agg(
             jsonb_build_object(
               'prenom', sub.prenom,
               'nom', sub.nom,
               'label', sub.label,
               'email', sub.email,
               'telephone', sub.telephone
             )
           )) AS mediateurs
    FROM (
      SELECT pal.lieu_id,
             p.prenom,
             p.nom,
             COALESCE(
               (p.contact -> 'coop') ->> 'email',
               (p.contact -> 'idposte') ->> 'mail_pro',
               (p.contact -> 'idposte') ->> 'mail_perso'
             ) AS email,
             COALESCE(
               (p.contact -> 'coop') ->> 'telephone',
               (p.contact -> 'idposte') ->> 'telephone'
             ) AS telephone,
             -- Une seule ligne par personne : labels cumulés, ordre CN → AC → Médiateur.
             ARRAY(
               SELECT lbl FROM (
                 SELECT 1 AS ord, 'Conseiller Numerique'::text AS lbl
                 WHERE flags.est_cn
                 UNION ALL
                 SELECT 2, 'Aidant Connect'
                 WHERE flags.est_ac
                 UNION ALL
                 SELECT 3, 'Médiateur numérique'
                 WHERE p.is_mediateur = TRUE
                   AND NOT flags.est_cn
                   AND NOT flags.est_ac
               ) labels
               ORDER BY ord
             ) AS label
      FROM main.personne_affectations_lieu pal
      JOIN main.personne p ON p.id = pal.personne_id
      CROSS JOIN LATERAL (
        SELECT
          (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL) AS est_cn,
          EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_ac
            WHERE pa_ac.personne_id = p.id
              AND pa_ac.source = 'aidants-connect'
              AND pa_ac.est_active = TRUE
          ) AS est_ac,
          EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_emp
            WHERE pa_emp.personne_id = p.id
              AND pa_emp.est_active = TRUE
              AND pa_emp.source <> 'aidants-connect'
          ) AS a_emploi_actif_non_ac
      ) flags
      WHERE pal.est_active = TRUE
        AND p.is_visible IS DISTINCT FROM FALSE
        AND (
          -- Aidant Connect actif
          flags.est_ac
          -- Conseiller Numérique avec un emploi actif non-AC
          OR (flags.est_cn AND flags.a_emploi_actif_non_ac)
          -- Médiateur numérique simple (ni CN ni AC actif)
          OR (p.is_mediateur = TRUE AND NOT flags.est_cn AND NOT flags.est_ac)
        )
    ) sub
    GROUP BY sub.lieu_id
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
);

COMMENT ON VIEW api.carto IS
  'Vue cartographie publique (V105). Source : main.lieu_inclusion + asso vers '
  'structure_administrative pour SIRET/RNA. Médiateurs : une ligne par personne '
  '(personne_affectations_lieu), labels cumulés CN/AC/Médiateur. Le label Aidant '
  'Connect requiert une affectation emploi aidants-connect active. Depuis #1348, '
  'le lieu reste exposé même si tous ses médiateurs sont inactifs (mediateurs = NULL).';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

NOTIFY pgrst, 'reload schema';
