-- Carto
-- Schema https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html
CREATE OR REPLACE VIEW api.carto AS (
WITH courriels AS (
   SELECT structure_1.id,
      string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text]), VARIADIC ARRAY[key.key]), '|'::text) AS courriels_concat
      FROM main.structure structure_1,
      LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text])) key(key)
      GROUP BY structure_1.id
   ),
   personnes AS (
      SELECT structure_id, 
         jsonb_strip_nulls(jsonb_agg(mediateurs)) AS mediateurs
      FROM (
         -- Conseiller Numerique
         SELECT structure_id, 
            jsonb_build_object(
               'prenom', prenom,
               'nom', nom,
               'label', CASE WHEN conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique', ',') ELSE Null END,
               'email', contact -> 'courriels' ->> 'mail_pro',
               'telephone', contact -> 'telephone'
            ) AS mediateurs
         FROM main.personne_affectations 
         INNER JOIN main.personne ON personne.id = personne_id AND personne_affectations.structure_id IS NOT NULL
         WHERE personne_affectations.suppression IS NULL
         AND personne_affectations.type = 'lieu_activite'
         AND (is_active_ac IS FALSE OR is_active_ac IS NULL OR aidant_connect_id IS NULL)
         AND (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL)
         UNION
         -- Aidant Connect ou (Aidant Connect et Conseiller Numerique)
         SELECT structure_id, 
            jsonb_build_object(
               'prenom', prenom,
               'nom', nom,
               'label', CASE WHEN conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique,Aidant Connect', ',') ELSE string_to_array('Aidant Connect', ',') END
            ) AS mediateurs
         FROM main.personne_affectations 
         INNER JOIN main.personne ON personne.id = personne_id AND personne_affectations.structure_id IS NOT NULL
         WHERE personne_affectations.suppression IS NULL
         AND personne_affectations.type = 'lieu_activite'
         AND (is_active_ac IS TRUE OR is_active_ac IS NOT NULL OR aidant_connect_id IS NOT NULL)
      ) as sub_table
      GROUP BY structure_id
    )
 SELECT structure.structure_cartographie_nationale_id AS id,
    (COALESCE(structure.siret, structure.rna, '00000000000000'::character varying))::character varying(14) AS pivot,
    structure.nom,
    adresse.nom_commune AS commune,
    adresse.code_postal,
    adresse.code_insee,
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    NULL::text AS complement_adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    array_to_string(structure.typologies, '|'::text) AS typologie,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source,
    array_to_string(structure.itinerance, '|'::text) AS itinerance,
    structure.structure_parente,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    array_to_string(structure.services, '|'::text) AS services,
    array_to_string(structure.publics_specifiquement_adresses, '|'::text) AS publics_specifiquement_adresses,
    array_to_string(structure.prise_en_charge_specifique, '|'::text) AS prise_en_charge_specifique,
    array_to_string(structure.frais_a_charge, '|'::text) AS frais_a_charge,
    array_to_string(structure.dispositif_programmes_nationaux, '|'::text) AS dispositif_programmes_nationaux,
    array_to_string(structure.formations_labels, '|'::text) AS formations_labels,
    array_to_string(structure.autres_formations_labels, '|'::text) AS autres_formations_labels,
    array_to_string(structure.modalites_acces, '|'::text) AS modalites_acces,
    array_to_string(structure.modalites_accompagnement, '|'::text) AS modalites_accompagnement,
    structure.fiche_acces_libre,
    structure.prise_rdv,
    personnes.mediateurs
   FROM main.structure
   LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
   LEFT JOIN courriels ON courriels.id = structure.id
   LEFT JOIN personnes ON personnes.structure_id = structure.id
  WHERE structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale
);

COMMENT ON VIEW api.carto IS 'Cartographie nationale de l''inclusion numérique. Schéma : https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html';

COMMENT ON column api.carto.pivot IS 'Siret pour les entreprises, RNA pour les associations sans Siret.';
COMMENT ON column api.carto.latitude IS 'Latitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.longitude IS 'Longitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.horaires IS 'Horaires au format OSM. cf. https://wiki.openstreetmap.org/wiki/Key:opening_hours/specification#explain:time_domain';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;



CREATE OR REPLACE FUNCTION api.get_carto_mediateur(familly_name text, first_name text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT jsonb_build_object(
        'nom', personne.nom, 
        'prenom', personne.prenom, 
        'lieux', jsonb_agg(
            jsonb_build_object(
            'id', structure.structure_cartographie_nationale_id,
            'pivot', (COALESCE(structure.siret, structure.rna, '00000000000000'::character varying))::character varying(14),
            'nom', structure.nom,
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
    INNER JOIN main.personne_affectations AS lieux ON lieux.personne_id = personne.id AND type = 'lieu_activite'
    INNER JOIN main.structure ON structure.id = lieux.structure_id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    WHERE personne.nom ILIKE familly_name || '%' 
        AND personne.prenom ILIKE first_name || '%'
    GROUP BY personne.nom, personne.prenom;
END;
$$;


COMMENT ON FUNCTION api.get_carto_mediateur IS 'Endpoint pour obtenir les lieux d''un médiateur à partir de ses nom et prénom.';

GRANT EXECUTE ON FUNCTION api.get_carto_mediateur TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
