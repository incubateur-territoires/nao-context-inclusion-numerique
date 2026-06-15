-- Rôle Postgres dédié à l'agent Nao — accès lecture seule, sans PII.
-- Exécuter en tant que superuser ou propriétaire des schémas.
--
-- Prérequis : exécuter 01_analytics_views.sql avant ce script.
--
-- Variables à adapter avant exécution :
--   - Mot de passe du rôle nao_readonly
--   - DEFAULT PRIVILEGES si de nouvelles tables analytics sont ajoutées

-- ---------------------------------------------------------------------------
-- 1. Création du rôle
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_readonly') THEN
    CREATE ROLE nao_readonly LOGIN PASSWORD 'CHANGE_ME';
  END IF;
END
$$;

COMMENT ON ROLE nao_readonly IS 'Lecture seule pour l''agent analytics Nao — tables et vues sans données personnelles.';

-- ---------------------------------------------------------------------------
-- 2. Schémas référentiels (accès complet en lecture)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA admin TO nao_readonly;
GRANT USAGE ON SCHEMA reference TO nao_readonly;

GRANT SELECT ON ALL TABLES IN SCHEMA admin TO nao_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA reference TO nao_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA admin GRANT SELECT ON TABLES TO nao_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA reference GRANT SELECT ON TABLES TO nao_readonly;

-- ---------------------------------------------------------------------------
-- 3. Schéma analytics (vues anonymisées Tier 3 + KPI agrégés)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA analytics TO nao_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO nao_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO nao_readonly;

-- ---------------------------------------------------------------------------
-- 4. Tables main/min autorisées (Tier 4)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA main TO nao_readonly;
GRANT USAGE ON SCHEMA min TO nao_readonly;

GRANT SELECT ON
  main.subvention,
  main.lieu_inclusion_structure_administrative
TO nao_readonly;

GRANT SELECT ON
  min.departement,
  min.region,
  min.groupement,
  min.enveloppe_financement,
  min.departement_enveloppe
TO nao_readonly;

-- ---------------------------------------------------------------------------
-- 5. Révocation explicite des tables sensibles (défense en profondeur)
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA main FROM nao_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA min FROM nao_readonly;

-- Ré-appliquer uniquement les grants autorisés après REVOKE global
GRANT SELECT ON
  main.subvention,
  main.lieu_inclusion_structure_administrative
TO nao_readonly;

GRANT SELECT ON
  min.departement,
  min.region,
  min.groupement,
  min.enveloppe_financement,
  min.departement_enveloppe
TO nao_readonly;

-- ---------------------------------------------------------------------------
-- 6. Vérification (à lancer manuellement après déploiement)
-- ---------------------------------------------------------------------------
-- SELECT table_schema, table_name, privilege_type
-- FROM information_schema.table_privileges
-- WHERE grantee = 'nao_readonly'
-- ORDER BY table_schema, table_name;
