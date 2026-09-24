CREATE INDEX personne_trgm_idx ON main.personne USING GIST ((prenom || ' ' || nom) gist_trgm_ops(siglen=64));

DROP FUNCTION api.get_carto_mediateur ( text, text) ;

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
    WHERE name % (personne.prenom || ' ' || personne.nom)
        AND structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale
    GROUP BY personne.nom, personne.prenom
    ORDER BY similarity(personne.prenom || ' ' || personne.nom, name) DESC;
END;
$$;


COMMENT ON FUNCTION api.get_carto_mediateur IS 'Endpoint pour obtenir les lieux d''un médiateur à partir de ses nom et prénom.';

GRANT EXECUTE ON FUNCTION api.get_carto_mediateur TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
