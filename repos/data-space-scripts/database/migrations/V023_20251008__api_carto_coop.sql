-- Carto
-- Schema https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html
DROP VIEW api.carto;

CREATE VIEW api.carto AS (
WITH courriels AS (
   SELECT structure_1.id,
      string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text]), VARIADIC ARRAY[key.key]), '|'::text) AS courriels_concat
      FROM main.structure structure_1,
      LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text])) key(key)
      GROUP BY structure_1.id
   ), personnes AS (
   SELECT sub_table.structure_id,
      jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
      FROM ( SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique'::text, ','::text)
                        ELSE NULL::text[]
                  END, 'email', (personne.contact -> 'courriels'::text) ->> 'mail_pro'::text, 'telephone', personne.contact -> 'telephone'::text) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.suppression IS NULL AND personne_affectations.type::text = 'lieu_activite'::text AND (personne.is_active_ac IS FALSE OR personne.is_active_ac IS NULL OR personne.aidant_connect_id IS NULL) AND (personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL)
            UNION
            SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique,Aidant Connect'::text, ','::text)
                        ELSE string_to_array('Aidant Connect'::text, ','::text)
                  END) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.suppression IS NULL AND personne_affectations.type::text = 'lieu_activite'::text AND (personne.is_active_ac IS TRUE OR personne.is_active_ac IS NOT NULL OR personne.aidant_connect_id IS NOT NULL)) sub_table
      GROUP BY sub_table.structure_id
   )
 SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000'::character varying)::character varying(14) AS pivot,
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


-- COOP
CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'courriels' ->> 'mail_pro' = email
       OR p.contact -> 'courriels' ->> 'mail_perso' = email
    LIMIT 1;

    RETURN QUERY
    WITH cn_coordonnes AS (
        SELECT coordinateur_id, 
        jsonb_agg(
            jsonb_build_object(
                'ids', jsonb_build_object(
                    'dataspace', personne.id, 
                    'aidant_connect', aidant_connect_id, 
                    'conseiller_numerique', conseiller_numerique_id, 
                    'cn_pg', cn_pg_id, 
                    'coop', coop_id),
                'nom', personne.nom, 
                'prenom', personne.prenom, 
                'contact', personne.contact
            )
        ) AS conseillers_numerique_coordonnes
        FROM main.coordination_mediation 
        INNER JOIN main.personne ON personne.id = mediateur_id
        WHERE coordination_mediation.en_cours = True
        AND coordinateur_id = var_personne_id
        GROUP BY coordinateur_id
    ),
    structures_employeuses AS (
        SELECT personne_id, 
            jsonb_agg(
                jsonb_build_object(
                    'siret', structure.siret,
                    'nom', structure.nom,
                    'contact', structure.contact,
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                )
            )
        ) AS structures
        FROM main.personne_affectations
        INNER JOIN main.structure ON structure.id = personne_affectations.structure_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE personne_affectations.personne_id = var_personne_id
        AND personne_affectations.type = 'structure_emploi'
        AND personne_affectations.suppression IS NULL
        GROUP BY personne_id
    ),
    lieux_activite AS (
        SELECT personne_id, 
        jsonb_agg(
            jsonb_build_object(
                'siret', structure.siret,
                'nom', structure.nom,
                'contact', structure.contact,
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                )
            )
        ) AS lieux
        FROM main.personne_affectations AS lieux
        INNER JOIN main.structure ON structure.structure_coop_id = lieux.structure_coop_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE personne_id = var_personne_id AND type = 'lieu_activite'
        GROUP BY personne_id
    ),
    contrats  AS (
        SELECT personne_id, 
        jsonb_agg(
            jsonb_build_object(
                'date_debut', date_debut, 
                'date_fin', date_fin, 
                'date_rupture', date_rupture, 
                'type', type
            )
        ) AS contrats
        FROM main.contrat 
        WHERE personne_id = var_personne_id
        GROUP BY personne_id
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN conseiller_numerique_id IS NOT NULL THEN True ELSE False END,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux,
        'contrats', contrats.contrats
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    LEFT JOIN contrats ON contrats.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, contrats.contrats;
END;
$$;


COMMENT ON FUNCTION api.get_mediateur IS 'Endpoint pour obtenir les infos d''un médiateur à partir de son courriel.';

GRANT EXECUTE ON FUNCTION api.get_mediateur TO postgrest_coop;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
