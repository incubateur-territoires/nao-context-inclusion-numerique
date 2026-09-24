-- Silver du flux QPV (zonage Quartiers Prioritaires de la Ville, mensuel) :
-- l'état transformé du run (GeoJSON WGS84 aplati : une ligne par (quartier,
-- code_insee), géométrie MultiPolygon en WKT) est matérialisé dans staging au
-- lieu du couple CSV working_dir + table de chargement import.qpv_staging.
-- Table reconstruite à chaque run (TRUNCATE + INSERT), relue par la capture
-- source et par l'insert vers admin.zonage.
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

CREATE TABLE staging.qpv__zonage (
    run_id      TEXT        NOT NULL,
    staged_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    geom_wkt    TEXT,
    code        TEXT,
    libelle     TEXT,
    code_insee  TEXT,
    type        TEXT        NOT NULL,
    source_file TEXT
);

-- L'ancienne table de chargement (créée à la volée par le DAG, jamais par
-- migration) n'a plus de producteur ni de lecteur.
DROP TABLE IF EXISTS import.qpv_staging;
