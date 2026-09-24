-- ============================================================
-- V147 – api.carto : fix courriels (clé 'emails' inexistante)
-- ============================================================
-- CONTEXTE :
-- Depuis V089 (2026-05-22), la CTE courriels lit li.contact->'emails', clé qui
-- n'existe pas dans le JSONB contact de main.lieu_inclusion (clés réelles :
-- telephone / courriels / site_web, avec courriels = objet {"email": ...}).
-- Résultat : api.carto publiait courriels = NULL sur 100 % des lignes (mesuré
-- 2026-07-30 : 0 non-NULL sur 18 438), alors que ~10 250 lieux ont un courriel.
--
-- FIX : lecture de la seule clé `email` de l'objet contact->'courriels'
-- (9 957 lieux — contact public, comme le lisait le legacy V057 côté
-- opendata). Toutes les autres clés restent exclues : `mail_gestionnaire`,
-- `referent_hierarchique`, `mail_N` portent des emails NOMINATIFS internes
-- (référents V047 posés par sonum/id-poste/MIN) jamais publiés, et `email_N`
-- est écarté aussi (décision 2026-07-30).
-- Le reste de la définition est strictement identique à V123.

DROP VIEW IF EXISTS api.carto;
CREATE VIEW api.carto AS (
  WITH courriels AS (
    SELECT li.id,
           string_agg(v.value, '|') AS courriels_concat
    FROM main.lieu_inclusion li,
         LATERAL jsonb_each_text(jsonb_extract_path(li.contact, 'courriels')) v
    WHERE v.key = 'email'
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
    '00000000000000'::character varying(14) AS pivot,
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
  LEFT JOIN courriels ON courriels.id = li.id
  LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    AND li.visible_pour_cartographie_nationale = TRUE
);

COMMENT ON VIEW api.carto IS
  'Vue cartographie publique. Source : main.lieu_inclusion. Depuis #1711 le lien '
  'lieu ↔ structure_administrative est supprimé : `pivot` (SIRET/RNA) n''est plus '
  'renseigné (fallback 00000000000000). Médiateurs : une ligne par personne '
  '(personne_affectations_lieu), labels cumulés CN/AC/Médiateur.';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

NOTIFY pgrst, 'reload schema';
