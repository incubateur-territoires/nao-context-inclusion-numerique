-- L'app MIN (rôle min_scalingo) a besoin de lire le schéma coop pour récupérer
-- les données d'accompagnements sur le tableau de bord structure.
-- Le schéma coop n'avait jamais été ouvert à min_scalingo.
-- Protection : ne rien faire si le schéma coop n'existe pas encore.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'coop') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA coop TO min_scalingo';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA coop TO min_scalingo';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA coop GRANT SELECT ON TABLES TO min_scalingo';
  END IF;
END
$$;
