DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'postgrest_coop') THEN

      RAISE NOTICE 'Role "postgrest_coop" already exists. Skipping.';
   ELSE
      CREATE ROLE postgrest_coop NOLOGIN;
      COMMENT ON ROLE postgrest_coop IS 'PostgREST Carto ANCT role';
   END IF;
END
$do$;


-- Allow app_api impersonate postgrest_coop
GRANT postgrest_coop TO app_api;


GRANT USAGE ON SCHEMA auth, api TO postgrest_coop;
GRANT EXECUTE ON FUNCTION auth.check_token TO postgrest_coop;
GRANT SELECT ON TABLE auth.token TO postgrest_coop;


CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    var_personne_id integer;
    var_personne_structure_id integer;
BEGIN
    -- Rechercher la personne par email
    SELECT p.id, p.structure_id
    INTO var_personne_id, var_personne_structure_id
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
    structure AS (
        SELECT structure.id AS structure_id, 
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
        ) AS structure
        FROM main.structure
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE structure.id = var_personne_structure_id
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
        'structure_employeuse', structure.structure,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux,
        'contrats', contrats.contrats
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structure ON structure.structure_id = personne.structure_id
    LEFT JOIN contrats ON contrats.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structure.structure, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, contrats.contrats;
END;
$$;


COMMENT ON FUNCTION api.get_mediateur IS 'Endpoint pour obtenir les infos d''un médiateur à partir de son courriel.';

GRANT EXECUTE ON FUNCTION api.get_mediateur TO postgrest_coop;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
