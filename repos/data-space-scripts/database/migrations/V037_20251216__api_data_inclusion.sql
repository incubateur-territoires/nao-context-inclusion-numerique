DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'postgrest_anct_data_incl') THEN

      RAISE NOTICE 'Role "postgrest_anct_data_incl" already exists. Skipping.';
   ELSE
      CREATE ROLE postgrest_anct_data_incl NOLOGIN;
      COMMENT ON ROLE postgrest_anct_data_incl IS 'PostgREST Data Inclusion ANCT role';
   END IF;
END
$do$;

GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
