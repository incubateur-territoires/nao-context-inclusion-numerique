-- Fraîcheur métier par source sur lieu_inclusion — ÉTAPE 2/2.
--
-- Bascule `updated_at` en colonne CALCULÉE = GREATEST des 3 colonnes source
-- (seedées en V115). Nécessite de DROP les 2 vues qui référencent `updated_at`
-- (api.carto, dataviz.structures), de recréer la colonne, puis de recréer les
-- vues À L'IDENTIQUE (même nom + même type de colonne → vues inchangées).
--
-- Dépendances vérifiées : aucune autre vue ne consomme api.carto ni
-- dataviz.structures (pas de DROP en cascade).

-- 1) Le trigger smart-updated_at n'a plus de raison d'être : updated_at devient calculée.
DROP TRIGGER IF EXISTS updated_at ON main.lieu_inclusion;
DROP TRIGGER IF EXISTS updated_at_insert ON main.lieu_inclusion;

-- 2) DROP des vues dépendantes de updated_at.
DROP VIEW IF EXISTS api.carto;
DROP VIEW IF EXISTS dataviz.structures;

-- 3) Bascule de updated_at en colonne calculée.
ALTER TABLE main.lieu_inclusion DROP COLUMN updated_at;
ALTER TABLE main.lieu_inclusion
    ADD COLUMN updated_at TIMESTAMP WITHOUT TIME ZONE
    GENERATED ALWAYS AS (GREATEST(updated_at_carto, updated_at_coop, updated_at_min)) STORED;

COMMENT ON COLUMN main.lieu_inclusion.updated_at IS
    'Date du dernier changement métier réel toutes sources confondues (colonne calculée).';

-- 4) Recréation de api.carto — STRICTEMENT identique à V105 (la colonne updated_at
--    recréée a même nom et même type, la vue est donc inchangée).
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

-- 5) Recréation de dataviz.structures — STRICTEMENT identique à V094.
--    Grant Metabase auto via ALTER DEFAULT PRIVILEGES IN SCHEMA dataviz (V005).
CREATE VIEW dataviz.structures AS (
  -- Cas 1 : SA mixte avec asso → 1 ligne par couple (SA, LI)
  SELECT
    sa.id,
    li.structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    COALESCE(li.adresse_id, sa.adresse_id) AS adresse_id,
    li.contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
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
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    li.fiche_acces_libre,
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
  JOIN main.lieu_inclusion_structure_administrative asso ON asso.structure_administrative_id = sa.id
  JOIN main.lieu_inclusion li ON li.id = asso.lieu_id
  LEFT JOIN main.adresse adresse ON adresse.id = COALESCE(li.adresse_id, sa.adresse_id)
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))

  UNION ALL

  -- Cas 2 : SA pure (sans asso) → 1 ligne, champs metier NULL
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
    NULL::text[] AS typologies,
    NULL::text AS presentation_resume,
    NULL::text AS presentation_detail,
    NULL::varchar AS horaires,
    NULL::varchar AS prise_rdv,
    NULL::text[] AS services,
    NULL::text[] AS publics_specifiquement_adresses,
    NULL::text[] AS prise_en_charge_specifique,
    NULL::text[] AS frais_a_charge,
    NULL::text[] AS dispositif_programmes_nationaux,
    NULL::text[] AS formations_labels,
    NULL::text[] AS autres_formations_labels,
    NULL::text[] AS itinerance,
    NULL::text[] AS modalites_acces,
    NULL::text[] AS modalites_accompagnement,
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
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.structure_administrative_id = sa.id
  )

  UNION ALL

  -- Cas 3 : LI pure (sans asso) → 1 ligne, champs SIRENE NULL
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
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.lieu_id = li.id
  )
);

COMMENT ON VIEW dataviz.structures IS
  'Vue dataviz refondue phase 5.5 (V094). UNION ALL 3 cas SA+LI / SA pure / LI pure.';

NOTIFY pgrst, 'reload schema';
