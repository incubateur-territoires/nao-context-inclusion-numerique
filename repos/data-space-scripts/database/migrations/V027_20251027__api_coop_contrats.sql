ALTER TABLE main.contrat ADD structure_id INTEGER;
ALTER TABLE main.contrat ADD CONSTRAINT contrat_structure_id_fkey FOREIGN KEY (structure_id) REFERENCES main.structure(id);


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
                    'pg_id', cn_pg_id, 
                    'coop', coop_id),
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
        SELECT personne_affectations.personne_id, structure.id, 
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', structure.id, 
                        'aidant_connect', structure_ac_id,
                        'coop', structure_coop_id,
                        'pg_id', structure_tp_id),
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
                    ),
                    'contrats', (SELECT
                    jsonb_agg(
                        jsonb_build_object(
                            'date_debut', contrat.date_debut, 
                            'date_fin', contrat.date_fin, 
                            'date_rupture', contrat.date_rupture, 
                            'type', contrat.type
                        )
                    ) 
                    FROM main.contrat 
                    WHERE contrat.structure_id = structure.id AND contrat.personne_id = personne_affectations.personne_id)
                )
            ) AS structures
        FROM main.personne_affectations
        INNER JOIN main.structure ON structure.id = personne_affectations.structure_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        WHERE personne_affectations.personne_id = var_personne_id
        AND personne_affectations.type = 'structure_emploi'
        AND personne_affectations.suppression IS NULL
        GROUP BY personne_affectations.personne_id, structure.id
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
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN conseiller_numerique_id IS NOT NULL THEN True ELSE False END,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux;
END;
$$;

COMMENT ON FUNCTION api.get_mediateur IS 'Endpoint pour obtenir les infos d''un médiateur à partir de son courriel.';

GRANT EXECUTE ON FUNCTION api.get_mediateur TO postgrest_coop;


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
    GROUP BY personne.id, personne.nom, personne.prenom;
END;
$$;


COMMENT ON FUNCTION api.get_carto_mediateur IS 'Endpoint pour obtenir les lieux d''un médiateur à partir de ses nom et prénom.';

GRANT EXECUTE ON FUNCTION api.get_carto_mediateur TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
