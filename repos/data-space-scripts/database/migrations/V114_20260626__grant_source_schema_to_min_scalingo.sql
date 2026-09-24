-- L'app MIN (rôle min_scalingo) a besoin de lire le schéma source pour accéder
-- aux données brutes capturées (append-only) par la couche source.
-- Protection : ne rien faire si le schéma source n'existe pas encore.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'source') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA source TO min_scalingo';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA source TO min_scalingo';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA source GRANT SELECT ON TABLES TO min_scalingo';
  END IF;
END
$$;
