DROP FUNCTION auth.create_role_n_token (character varying, character varying, character varying, text, date, character varying) ;
DROP FUNCTION auth.add_token (character varying, character varying, character varying) ;

-- Declare token in auth.token
CREATE OR REPLACE FUNCTION auth.add_token(token_id varchar(50), username varchar(50), expiration_date timestamp, comment varchar(50)) RETURNS VOID AS $$
  INSERT INTO auth.token (token_id, pg_role, expiration_date, comment)
  VALUES (token_id, username, expiration_date, comment)
  ON CONFLICT ON CONSTRAINT token_token_id_key DO NOTHING;
$$ LANGUAGE sql;

-- Meta function to create a new role and token
CREATE OR REPLACE FUNCTION auth.create_role_n_token(role_name character varying(50), role_description character varying(50), token_id character varying(50), postgrest_secret text, expiration_date timestamp, token_description character varying(255) DEFAULT Null) RETURNS void
  LANGUAGE plpgsql
  AS $$
DECLARE
  jwt TEXT;
  BEGIN
    -- Create role
    IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = role_name) THEN

      RAISE NOTICE 'Role "%" already exists. Skipping.', role_name;
    ELSE
      EXECUTE format('CREATE ROLE %I NOLOGIN;
        COMMENT ON ROLE %I IS %L;',
        role_name, role_name, role_description);
    END IF;

  -- Allow app_api impersonate $role_name
  EXECUTE format('GRANT %I TO app_api', role_name);
  RAISE INFO 'Impersonation: ok';

  -- Need Usage on api schema to access to view(s)
  -- Need Usage on auth schema to access to table `token` and `check_token` function
  EXECUTE format('GRANT USAGE ON SCHEMA auth, api TO %I;
    GRANT EXECUTE ON FUNCTION auth.check_token TO %I;
    GRANT SELECT ON TABLE auth.token TO %I;',
    role_name, role_name, role_name);
  RAISE INFO 'Access: ok';

  -- Generate the JSON Web Token (l'id du token (permettant sa déactivation), PostgreSQL role, datetime d'expiration, 'le SECRET de PostgREST')
  EXECUTE format('
    SELECT auth.create_jwt(%L, %L, %L, %L)
    ', token_id, role_name, (expiration_date::timestamp + INTERVAL '1 day - 1 microsecond')::timestamp, postgrest_secret)
    INTO jwt;
  RAISE NOTICE 'JWT: %', jwt;

  -- Add the token declaration in `auth.token`
  EXECUTE format('
    SELECT auth.add_token(%L, %L, %L, %L)', 
    token_id, role_name,  (expiration_date::timestamp + INTERVAL '1 day - 1 microsecond')::timestamp, concat_ws(' ', token_description, 'Token valid until', (expiration_date::timestamp + INTERVAL '1 day - 1 microsecond')::timestamp));
  RAISE INFO 'Token authorization: ok';

  RAISE NOTICE 'Vous pouvez maintenant attribuer les droits sur la(les) table(s)/vue(s) au rôle %;', role_name;

END;
$$;

COMMENT ON FUNCTION auth.create_role_n_token IS 'Création du rôle si inexistant puis création et activation du token.\nLes droits sur le(s) table(s)/vue(s) restent à attribuer.';
