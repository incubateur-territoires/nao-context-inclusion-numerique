-- ============================================================
-- V101 – api.carto : une ligne médiateur par personne + label AC sur affectation active
-- ============================================================
-- CONTEXTE :
-- La vue api.carto (définie en V089) construisait son tableau `mediateurs`
-- via un UNION de 3 sous-requêtes (CN seul / AC / médiateur simple). Deux défauts :
--
--   1. Doublons. Une personne CN possédant aussi un aidant_connect_id mais dont
--      l'affectation emploi 'aidants-connect' est INACTIVE tombait à la fois dans
--      la branche 1 (« CN seul », dont le garde-fou ne testait que les AC *actifs*)
--      et dans la branche 2 (« AC », garde-fou large sur aidant_connect_id IS NOT NULL).
--      Résultat : deux entrées pour la même personne, l'une labellisée
--      ["Conseiller Numerique"], l'autre ["Conseiller Numerique","Aidant Connect"],
--      avec des coordonnées identiques. Constaté sur le lieu « Mairie de Certines »
--      (coop_id 63e4fbe0-…) : POUJOL et BERTIN sortaient chacun en double.
--      Mesuré le 2026-06-12 : 666 couples (lieu, personne) émis en double.
--
--   2. Sémantique AC incohérente. Le label « Aidant Connect » était posé dès que
--      aidant_connect_id était renseigné, même sans affectation AC active — donc des
--      personnes dont l'habilitation AC est inactive restaient annoncées AC sur la
--      cartographie publique.
--
-- REFONTE :
--   - Le tableau `mediateurs` produit désormais UNE ligne par personne, labels
--     cumulés dans l'ordre CN → AC → Médiateur numérique.
--   - Le label « Aidant Connect » n'est posé que si une affectation emploi
--     'aidants-connect' est est_active = TRUE (cohérent avec le reste de la vue, qui
--     filtre déjà sur les affectations emploi actives).
--   - Conséquence : une personne dont le SEUL motif d'apparition était une affectation
--     AC inactive (ni CN+emploi actif, ni médiateur simple éligible) ne paraît plus.
--     Mesuré le 2026-06-12 : 28 couples (lieu, personne) retirés.
--
-- Le reste de la vue (CTE courriels, SELECT final, JOINs, filtre des lieux) est
-- inchangé par rapport à V089.
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
  'Vue cartographie publique (V101). Source : main.lieu_inclusion + asso vers '
  'structure_administrative pour SIRET/RNA. Médiateurs : une ligne par personne '
  '(personne_affectations_lieu), labels cumulés CN/AC/Médiateur. Le label Aidant '
  'Connect requiert une affectation emploi aidants-connect active.';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

NOTIFY pgrst, 'reload schema';
