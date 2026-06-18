-- Rôle Postgres dédié à l'agent Nao — accès lecture seule, sans PII.
-- Exécuter en tant que superuser ou propriétaire des schémas.
--
-- Prérequis : exécuter 00_llm_views.sql et 01_analytics_views.sql avant ce script.
--
-- Variables à adapter avant exécution :
--   - Mot de passe du rôle nao_ro
--   - DEFAULT PRIVILEGES si de nouvelles vues llm ou analytics sont ajoutées

-- ---------------------------------------------------------------------------
-- 1. Création du rôle
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    CREATE ROLE nao_ro LOGIN PASSWORD 'CHANGE_ME';
  END IF;
END
$$;

COMMENT ON ROLE nao_ro IS 'Lecture seule pour l''agent analytics Nao — vues llm.* et analytics.* sans données personnelles.';

-- ---------------------------------------------------------------------------
-- 2. Schémas référentiels (accès complet en lecture)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA admin TO nao_ro;
GRANT USAGE ON SCHEMA reference TO nao_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA admin TO nao_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA reference TO nao_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA admin GRANT SELECT ON TABLES TO nao_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA reference GRANT SELECT ON TABLES TO nao_ro;

-- ---------------------------------------------------------------------------
-- 3. Schéma llm (vues anonymisées Tier 1 + structures)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA llm TO nao_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA llm TO nao_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA llm GRANT SELECT ON TABLES TO nao_ro;

-- ---------------------------------------------------------------------------
-- 4. Schéma analytics (lieux, adresses, KPI agrégés)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA analytics TO nao_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO nao_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO nao_ro;

-- ---------------------------------------------------------------------------
-- 5. Tables main/min autorisées (Tier 4)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA main TO nao_ro;
GRANT USAGE ON SCHEMA min TO nao_ro;

GRANT SELECT ON
  main.subvention,
  main.lieu_inclusion_structure_administrative
TO nao_ro;

GRANT SELECT ON
  min.departement,
  min.region,
  min.groupement,
  min.enveloppe_financement,
  min.departement_enveloppe
TO nao_ro;

-- ---------------------------------------------------------------------------
-- 6. Révocation explicite des tables sensibles (défense en profondeur)
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA main FROM nao_ro;
REVOKE ALL ON ALL TABLES IN SCHEMA min FROM nao_ro;

-- Ré-appliquer uniquement les grants autorisés après REVOKE global
GRANT SELECT ON
  main.subvention,
  main.lieu_inclusion_structure_administrative
TO nao_ro;

GRANT SELECT ON
  min.departement,
  min.region,
  min.groupement,
  min.enveloppe_financement,
  min.departement_enveloppe
TO nao_ro;

-- ---------------------------------------------------------------------------
-- 7. Vérification (à lancer manuellement après déploiement)
-- ---------------------------------------------------------------------------
-- SELECT table_schema, table_name, privilege_type
-- FROM information_schema.table_privileges
-- WHERE grantee = 'nao_ro'
-- ORDER BY table_schema, table_name;
