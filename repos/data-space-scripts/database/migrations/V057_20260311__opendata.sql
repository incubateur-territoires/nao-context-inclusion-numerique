CREATE SCHEMA opendata;

GRANT USAGE ON SCHEMA opendata TO app_python;

CREATE VIEW opendata.lieux_mednum AS (
    SELECT 
        structure_cartographie_nationale_id AS id,
        COALESCE(siret, rna) AS pivot,
        nom AS nom,
        adresse.nom_commune AS commune,
        adresse.code_postal AS code_postal,
        adresse.code_insee AS code_insee,
        concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
        NULL AS complement_adresse,
        ST_Y(adresse.geom) AS latitude,
        ST_X(adresse.geom) AS longitude,
        array_to_string(typologies, '|'::text) AS typologie,
        structure.contact ->> 'telephone' AS telephone,
        structure.contact -> 'courriels' ->> 'email' AS courriels,
        structure.contact ->> 'site_web' AS site_web,
        horaires AS horaires,
        presentation_resume AS presentation_resume,
        presentation_detail AS presentation_detail,
        source AS source,
        array_to_string(itinerance, '|'::text) AS itinerance,
        NULL AS structure_parente,
        COALESCE(structure.updated_at, structure.created_at) AS date_maj,
        array_to_string(services, '|'::text) AS services,
        array_to_string(publics_specifiquement_adresses, '|'::text) AS publics_specifiquement_adresses,
        array_to_string(prise_en_charge_specifique, '|'::text) AS prise_en_charge_specifique,
        array_to_string(frais_a_charge, '|'::text) AS frais_a_charge,
        array_to_string(dispositif_programmes_nationaux, '|'::text) AS dispositif_programmes_nationaux,
        array_to_string(formations_labels, '|'::text) AS formations_labels,
        array_to_string(autres_formations_labels, '|'::text) AS autres_formations_labels,
        array_to_string(modalites_acces, '|'::text) AS modalites_acces,
        array_to_string(modalites_accompagnement, '|'::text) AS modalites_accompagnement,
        fiche_acces_libre AS fiche_acces_libre,
        prise_rdv AS prise_rdv
    FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    WHERE structure_cartographie_nationale_id IS NOT NULL OR visible_pour_cartographie_nationale
);

COMMENT ON VIEW opendata.lieux_mednum IS 'Vue des lieux médiation numérique au format de la MédNum';

GRANT SELECT ON TABLE opendata.lieux_mednum TO app_python;

CREATE VIEW opendata.lieux_geojson AS (
    WITH features AS (
        SELECT geom,
        structure_cartographie_nationale_id,
        siret,
        rna,
        nom,
        jsonb_build_object(
            'numero_voie', adresse.numero_voie,
            'repetition', adresse.repetition,
            'nom_voie', adresse.nom_voie,
            'code_postal', adresse.code_postal,
            'nom_commune', adresse.nom_commune,
            'code_insee', adresse.code_insee,
            'clef_interop', adresse.clef_interop,
            'code_ban', adresse.code_ban
        ) AS adresse,
        typologies, contact AS contacts, horaires, presentation_resume, presentation_detail, source, itinerance, services, publics_specifiquement_adresses, prise_en_charge_specifique, frais_a_charge, dispositif_programmes_nationaux, formations_labels, autres_formations_labels, modalites_acces, modalites_accompagnement, fiche_acces_libre, prise_rdv
        FROM main.structure
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        WHERE structure_cartographie_nationale_id IS NOT NULL OR visible_pour_cartographie_nationale
    )
    SELECT jsonb_build_object(
        'type', 'FeatureCollection',
        'features', json_agg(ST_AsGeoJSON(features.*)::jsonb)
        )
    FROM features
);

COMMENT ON VIEW opendata.lieux_geojson IS 'Vue des lieux médiation numérique pour publication au format GeoJSON';

GRANT SELECT ON TABLE opendata.lieux_geojson TO app_python;
