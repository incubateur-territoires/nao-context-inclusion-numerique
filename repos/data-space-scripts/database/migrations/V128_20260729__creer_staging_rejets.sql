-- Quarantaine des lignes écartées par le pipeline (fiche 03 approche-data,
-- étape 2 de la feuille de route) : « on ne droppe jamais silencieusement ».
-- Chaque filtre d'exclusion des transformations écrit ici la ligne complète
-- écartée, avec son motif — au lieu d'un simple log ou d'un drop muet.
--
-- Nouveau schéma staging (première brique ; accueillera les états
-- intermédiaires de l'étape 4 ELT). Pattern GRANTS de V002/V004 :
-- ALTER DEFAULT PRIVILEGES tables + séquences pour app_python.
--
-- Colonnes (cf. fiche 03 §2) :
--   rejete_at   horodatage du rejet
--   run_id      dag_run Airflow (corrélation avec source.capture_run)
--   flux        flux concerné, convention source (ex. 'carto__structures')
--   etape       étape du pipeline qui a écarté la ligne (ex. 'ingest')
--   motif       raison courte et stable (ex. 'id_trop_long')
--   source_key  clé d'origine de la ligne si connue
--   payload     la ligne écartée, complète, en JSONB

CREATE SCHEMA IF NOT EXISTS staging;

GRANT USAGE ON SCHEMA staging TO app_python;

ALTER DEFAULT PRIVILEGES IN SCHEMA staging
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO app_python;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
    GRANT USAGE, UPDATE ON SEQUENCES TO app_python;

CREATE TABLE staging.rejets (
    id         BIGSERIAL   PRIMARY KEY,
    rejete_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_id     TEXT,
    flux       TEXT        NOT NULL,
    etape      TEXT        NOT NULL,
    motif      TEXT        NOT NULL,
    source_key TEXT,
    payload    JSONB       NOT NULL
);

-- Suivi du taux de rejet par flux (fiche 06) : accès par flux, récent d'abord.
CREATE INDEX rejets_flux_rejete_at_idx
    ON staging.rejets (flux, rejete_at DESC);
