-- ============================================================
-- V123 – Suppression de la table d'association lieu ⋈ structure administrative
-- ============================================================
-- CONTEXTE (ticket SEPT #1711) :
-- Le lien lieu_inclusion ↔ structure_administrative (table
-- main.lieu_inclusion_structure_administrative) s'est révélé lâche et de
-- mauvaise qualité : 7 sources d'écriture non qualifiées, ~50 % de lignes non
-- corroborées, aucun cycle de vie (le coop-dag n'ajoute jamais ne supprime),
-- stock SIRET gelé (V093) arbitraire sur les collisions d'antennes AC. Après
-- validation PO, ce lien n'est pas indispensable : les données régaliennes
-- (financements, conventions) vivent sur SA + postes, jamais sur ce rattachement.
--
-- Côté application (MIN), la lecture de l'asso a été retirée (PR #1714, déployée
-- avant cette migration). Cette migration retire la table côté entrepôt.
--
-- DÉMARCHE : réécrire les 6 vues + 2 fonctions live qui joignent l'asso pour
-- qu'elles n'en dépendent plus (coupe franche — pas de repli via
-- structure_coop_id), puis DROP TABLE.
--
-- IMPACT OPENDATA ASSUMÉ (dataspace_dev) :
--   - api.carto / api.get_carto_mediateur : `pivot` (SIRET/RNA du lieu) retombe
--     sur le fallback '00000000000000' (aucune ligne perdue) — 2 131 lieux
--     concernés.
--   - api.structures / dataviz.structures : la branche appariée SA×LI disparaît ;
--     les vues deviennent deux listes disjointes (toutes les SA + tous les LI).
--   - api.aidants_connect : l'adresse retombe sur celle de la SA employeuse.
--   - dataviz.lieux_inclusion_numerique : colonnes SIRENE (siret/rna/catégorie
--     juridique/état) → NULL.
--   - dataviz.structures_employeuses : nombre_accompagnements_médiateurs_numériques,
--     nombre_de_médiateurs et est_france_services → vides.
--   - api.get_mediateur : siret et contacts des lieux d'activité → NULL / [].
-- ============================================================

-- ------------------------------------------------------------
-- 1) api.carto — pivot SIRET/RNA retiré (fallback constant).
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 2) api.structures — deux listes disjointes (toutes SA + tous LI).
-- ------------------------------------------------------------
DROP VIEW IF EXISTS api.structures;
CREATE VIEW api.structures AS (
  -- 1) Structures administratives (entités légales) : nom = denomination_sirene
  SELECT
    sa.siret,
    sa.rna,
    sa.denomination_sirene AS nom,
    sa.code_activite_principale,
    sa.etat_administratif,
    sa.denomination_sirene,
    sa.categorie_juridique AS code_categorie_juridique,
    cj.nom AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse a ON a.id = sa.adresse_id
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text

  UNION ALL

  -- 2) Lieux d'inclusion (lieux physiques) : siret/rna/SIRENE = NULL
  SELECT
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    li.nom,
    NULL::varchar AS code_activite_principale,
    NULL::varchar AS etat_administratif,
    NULL::varchar AS denomination_sirene,
    NULL::varchar AS code_categorie_juridique,
    NULL::varchar AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse a ON a.id = li.adresse_id
);

COMMENT ON VIEW api.structures IS
  'Vue de compatibilité — depuis #1711 le lien lieu ↔ SA est supprimé : deux '
  'listes disjointes (toutes les structures administratives + tous les lieux '
  'd''inclusion), sans appariement.';

GRANT SELECT ON TABLE api.structures TO postgrest_anct_dev;

-- ------------------------------------------------------------
-- 3) api.aidants_connect — l'adresse du lieu retombe sur celle de la SA.
-- ------------------------------------------------------------
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
      -- 1) Emploi prioritaire : SA (adresse et nom = ceux de la SA).
      SELECT
        pae.personne_id,
        sa.id AS structure_id,
        sa.denomination_sirene AS nom,
        concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
        a.code_insee,
        a.nom_commune AS commune,
        a.departement AS code_departement,
        0 AS priority,
        COALESCE(pae.updated_at, pae.created_at) AS ts,
        pae.id AS aff_id
      FROM main.personne_affectations_emploi pae
      JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
      LEFT JOIN main.adresse a ON a.id = sa.adresse_id
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
  'Vue de compat. Résout la structure employeuse d''un aidant via '
  'personne_affectations_emploi (SA) en priorité, fallback sur '
  'personne_affectations_lieu (LI). Depuis #1711 (suppression du lien lieu ↔ SA), '
  'l''adresse du cas emploi vient de la SA employeuse.';

GRANT SELECT ON TABLE api.aidants_connect TO postgrest_anct_incub;

-- ------------------------------------------------------------
-- 4) dataviz.structures — deux listes disjointes (toutes SA + tous LI).
-- ------------------------------------------------------------
DROP VIEW IF EXISTS dataviz.structures;
CREATE VIEW dataviz.structures AS (
  -- Cas 1 : structures administratives (champs LI à NULL)
  SELECT
    sa.id,
    NULL::uuid AS structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    sa.adresse_id,
    NULL::jsonb AS contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    NULL::varchar AS structure_cartographie_nationale_id,
    NULL::boolean AS visible_pour_cartographie_nationale,
    NULL::main.typologie[] AS typologies,
    NULL::text AS presentation_resume,
    NULL::text AS presentation_detail,
    NULL::varchar AS horaires,
    NULL::varchar AS prise_rdv,
    NULL::main.service[] AS services,
    NULL::main.public_specifiquement_adresse[] AS publics_specifiquement_adresses,
    NULL::main.prise_en_charge_specifique[] AS prise_en_charge_specifique,
    NULL::main.frais_a_charge[] AS frais_a_charge,
    NULL::main.dispositif_programme_national[] AS dispositif_programmes_nationaux,
    NULL::main.formation_label[] AS formations_labels,
    NULL::text[] AS autres_formations_labels,
    NULL::main.itinerance[] AS itinerance,
    NULL::main.modalite_acces[] AS modalites_acces,
    NULL::main.modalite_accompagnement[] AS modalites_accompagnement,
    NULL::integer AS mediateurs_en_activite,
    NULL::integer AS emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    NULL::varchar AS fiche_acces_libre,
    sa.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))

  UNION ALL

  -- Cas 2 : lieux d'inclusion (champs SIRENE à NULL)
  SELECT
    li.id,
    li.structure_coop_id,
    NULL::uuid AS structure_ac_id,
    NULL::integer AS structure_tp_id,
    li.nom,
    NULL::varchar AS denomination_sirene,
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    li.adresse_id,
    li.contact,
    NULL::varchar AS etat_administratif,
    NULL::varchar AS code_activite_principale,
    NULL::varchar AS categorie_juridique,
    NULL::integer AS nb_mandats_ac,
    NULL::boolean AS publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    NULL::date AS last_sirene_enrich_at,
    li.created_at,
    li.updated_at,
    li.fiche_acces_libre,
    li.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    NULL::text AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
);

COMMENT ON VIEW dataviz.structures IS
  'Vue dataviz. Depuis #1711 le lien lieu ↔ SA est supprimé : deux listes '
  'disjointes (toutes les SA + tous les LI), sans appariement.';

-- ------------------------------------------------------------
-- 5) dataviz.lieux_inclusion_numerique — colonnes SIRENE à NULL.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS dataviz.lieux_inclusion_numerique;
CREATE VIEW dataviz.lieux_inclusion_numerique AS (
  WITH conseillers AS (
    SELECT pal.lieu_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_lieu pal ON pal.personne_id = p.id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pal.est_active = TRUE
    GROUP BY pal.lieu_id
  ), coop_lieu AS (
    SELECT lieu_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY lieu_id
  )
  SELECT
    li.id AS structure_id,
    li.nom,
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    NULL::text AS "catégorie_juridique_de_la_structure",
    NULL::varchar AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    li.presentation_resume AS "présentation_résumée",
    li.presentation_detail AS "présentation_détaillée",
    li.horaires AS horaires_accueil,
    array_to_string(li.services, ', ') AS "services_proposés",
    array_to_string(li.dispositif_programmes_nationaux, ', ') AS dispositifs_nationaux,
    array_to_string(
      li.formations_labels::text[] ||
      NULLIF(NULLIF(NULLIF(li.autres_formations_labels, '{ZRR}'::text[]), '{QPV}'::text[]), '{QPV,ZRR}'::text[]),
      ', '
    ) AS formations,
    array_to_string(li.itinerance, ', ') AS "itinérance",
    array_to_string(li.modalites_acces, ', ') AS "modalités_accès",
    array_to_string(li.modalites_accompagnement, ', ') AS "modalités_accompagnement",
    li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coop_lieu.nbr AS nombre_accompagnements,
    array_to_string(li.typologies, ', ') AS typologies,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN 'France Services' = ANY (li.dispositif_programmes_nationaux) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services,
    CASE WHEN li.structure_coop_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse ON li.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN conseillers ON li.id = conseillers.lieu_id
  LEFT JOIN coop_lieu ON li.id = coop_lieu.lieu_id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
);

COMMENT ON VIEW dataviz.lieux_inclusion_numerique IS
  'Vue dataviz côté LI. Depuis #1711 (suppression du lien lieu ↔ SA), les '
  'colonnes SIRENE (siret/rna/catégorie juridique/état) ne sont plus renseignées.';

-- ------------------------------------------------------------
-- 6) dataviz.structures_employeuses — agrégats lieu→SA retirés.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS dataviz.structures_employeuses;
CREATE VIEW dataviz.structures_employeuses AS (
  WITH coordinateurs AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE p.is_coordinateur IS TRUE AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), conseillers AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), aidants_connect AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr_rattach,
           SUM(COALESCE(
             CASE WHEN sa.structure_ac_id IS NOT NULL THEN p.nb_accompagnements_ac ELSE 0 END,
             0
           )) AS nbr_accompagnements
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id AND pae.est_active = TRUE
    LEFT JOIN main.structure_administrative sa ON pae.structure_administrative_id = sa.id
    WHERE EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pae2
            WHERE pae2.personne_id = p.id
              AND pae2.source = 'aidants-connect'
              AND pae2.est_active = TRUE
          )
       OR p.aidant_connect_id IS NOT NULL
    GROUP BY pae.structure_administrative_id
  )
  SELECT
    sa.id AS structure_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.siret,
    sa.rna,
    sa.code_activite_principale AS code_naf,
    cj.nom AS "catégorie_juridique_de_la_structure",
    sa.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN COALESCE(conseillers.nbr, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_conum,
    CASE WHEN COALESCE(aidants_connect.nbr_rattach, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_aidant_connect,
    'Non'::text AS est_france_services,
    NULL::integer AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    aidants_connect.nbr_rattach AS nombre_aidants_connect,
    coordinateurs.nbr AS nombre_de_coordinateurs,
    sa.nb_mandats_ac AS mandats_aidants_connect,
    aidants_connect.nbr_accompagnements AS accompagnements_aidants_connect,
    NULL::bigint AS "nombre_accompagnements_médiateurs_numériques",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN coordinateurs ON sa.id = coordinateurs.structure_administrative_id
  LEFT JOIN conseillers ON sa.id = conseillers.structure_administrative_id
  LEFT JOIN aidants_connect ON sa.id = aidants_connect.structure_administrative_id
);

COMMENT ON VIEW dataviz.structures_employeuses IS
  'Vue dataviz SA + paf_emploi. Depuis #1711 (suppression du lien lieu ↔ SA), '
  'les agrégats portés par les lieux (nombre_accompagnements_médiateurs_numériques, '
  'nombre_de_médiateurs, est_france_services) ne sont plus renseignés.';

-- ------------------------------------------------------------
-- 7) api.get_carto_mediateur — pivot SIRET/RNA retiré (fallback constant).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_carto_mediateur(name text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    SET pg_trgm.similarity_threshold = 0.5;

    RETURN QUERY
    SELECT jsonb_build_object(
        'nom', personne.nom,
        'prenom', personne.prenom,
        'lieux', jsonb_agg(
            jsonb_build_object(
            'id', li.structure_cartographie_nationale_id,
            'pivot', '00000000000000'::character varying(14),
            'nom', li.nom,
            'commune', adresse.nom_commune,
            'code_postal', adresse.code_postal,
            'code_insee', adresse.code_insee,
            'adresse', concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie),
            'complement_adresse', NULL::text,
            'latitude', st_y(adresse.geom),
            'longitude', st_x(adresse.geom)
            )
        )
    )
    FROM main.personne
    INNER JOIN main.personne_affectations_lieu AS lieux ON lieux.personne_id = personne.id
    INNER JOIN main.lieu_inclusion li ON li.id = lieux.lieu_id
    LEFT JOIN main.adresse ON li.adresse_id = adresse.id
    WHERE name % (personne.prenom || ' ' || personne.nom)
        AND personne.is_visible IS DISTINCT FROM FALSE
        AND li.structure_cartographie_nationale_id IS NOT NULL AND li.visible_pour_cartographie_nationale
        AND EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_emploi
            WHERE pa_emploi.personne_id = personne.id
                AND pa_emploi.est_active = true
                AND pa_emploi.source != 'aidants-connect'
        )
    GROUP BY personne.nom, personne.prenom
    ORDER BY similarity(personne.prenom || ' ' || personne.nom, name) DESC;
END;
$$;

COMMENT ON FUNCTION api.get_carto_mediateur IS $$Obtenir les lieux d'activité d'un médiateur à partir de ses nom et prénom.
L'ordre nom-prénom, prénom-nom n'a pas d'impact, la recherche est insensible à la casse et permissive à des fautes de frappe grâce à l'usage des trigrammes.
Uniquement les personnes ayant un score de similarité > 0.5 seront prises en compte.
Les personnes ayant fait part de leur souhait de ne pas apparaître publiquement (is_visible = FALSE) ne sont pas prises en compte.
Depuis #1711 (suppression du lien lieu ↔ SA), le champ « pivot » (SIRET/RNA) n'est plus renseigné.$$;

GRANT EXECUTE ON FUNCTION api.get_carto_mediateur TO postgrest_anct_carto;

-- ------------------------------------------------------------
-- 8) api.get_mediateur — siret et contacts des lieux d'activité retirés.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email (toutes sources)
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'coop' ->> 'email' = email
       OR p.contact -> 'idposte' ->> 'mail_pro' = email
       OR p.contact -> 'idposte' ->> 'mail_perso' = email
    LIMIT 1;

    RETURN QUERY
    WITH cn_coordonnes AS (
        SELECT coordinateur_id,
        jsonb_agg(
            jsonb_build_object(
                'ids', jsonb_build_object(
                    'dataspace', personne.id,
                    'aidant_connect', personne.aidant_connect_id,
                    'conseiller_numerique', personne.conseiller_numerique_id,
                    'pg_id', personne.cn_pg_id,
                    'coop', personne.coop_id),
                'nom', personne.nom,
                'prenom', personne.prenom,
                'contact', personne.contact
            )
        ) AS conseillers_numerique_coordonnes
        FROM main.coordination_mediation
        INNER JOIN main.personne ON personne.id = mediateur_id
        WHERE coordination_mediation.suppression IS NULL
        AND coordinateur_id = var_personne_id
        GROUP BY coordinateur_id
    ),
    structures_employeuses AS (
        SELECT pae.personne_id,
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', sa.id,
                        'aidant_connect', sa.structure_ac_id,
                        'coop', sa.structure_coop_id,
                        'pg_id', sa.structure_tp_id),
                    'siret', sa.siret,
                    'nom', COALESCE(sa.denomination_antenne, sa.denomination_sirene),
                    'contacts', (
                        SELECT COALESCE(jsonb_agg(
                            jsonb_build_object(
                                'nom', c.nom,
                                'prenom', c.prenom,
                                'email', c.email,
                                'telephone', c.telephone,
                                'fonction', c.fonction,
                                'est_referent_fne', c.est_referent_fne
                            )
                        ), '[]'::jsonb)
                        FROM main.contact_structure_administrative cs
                        JOIN main.contact c ON c.id = cs.contact_id
                        WHERE cs.structure_administrative_id = sa.id
                    ),
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                    ),
                    'contrats', (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'date_debut', contrat.date_debut,
                                'date_fin', contrat.date_fin,
                                'date_rupture', contrat.date_rupture,
                                'type', contrat.type
                            )
                        )
                        FROM main.contrat
                        WHERE (contrat.structure_id = sa.id OR contrat.structure_id IS NULL)
                          AND contrat.personne_id = pae.personne_id
                    )
                )
            ) AS structures
        FROM (
            SELECT DISTINCT personne_id, structure_administrative_id
            FROM main.personne_affectations_emploi
            WHERE personne_id = var_personne_id
        ) pae
        INNER JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
        LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
        GROUP BY pae.personne_id
    ),
    lieux_activite AS (
        SELECT pal.personne_id,
        jsonb_agg(
            jsonb_build_object(
                'siret', NULL::varchar,
                'nom', li.nom,
                'contacts', '[]'::jsonb,
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                ),
                'id_carto', li.structure_cartographie_nationale_id
            )
        ) AS lieux
        FROM main.personne_affectations_lieu pal
        INNER JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
        LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
        WHERE pal.personne_id = var_personne_id
        GROUP BY pal.personne_id
    ),
    is_cn AS (
        SELECT pae.personne_id
        FROM main.personne_affectations_emploi pae
        WHERE pae.personne_id = var_personne_id
        AND pae.source = 'idposte'
        AND pae.est_active = TRUE
        LIMIT 1
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN is_cn.personne_id IS NOT NULL THEN True ELSE False END,
        'pg_id', personne.cn_pg_id,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    LEFT JOIN is_cn ON is_cn.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, is_cn.personne_id;
END;
$function$;

-- ------------------------------------------------------------
-- 9) Plus aucune vue/fonction ne dépend de l'asso : DROP TABLE.
-- ------------------------------------------------------------
DROP TABLE main.lieu_inclusion_structure_administrative;

NOTIFY pgrst, 'reload schema';
