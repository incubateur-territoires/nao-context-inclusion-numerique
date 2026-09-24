-- Couche "source" brute (raw / bronze) : capture append-only des données
-- telles que reçues de chaque source, AVANT toute transformation.
-- Objectifs : rejouer un run passé, tracer les erreurs (reçu vs chargé),
-- auditer l'évolution des données dans le temps.
--
-- Schéma + GRANTS (pattern V001 du schéma import via ALTER DEFAULT PRIVILEGES,
-- hérité par toutes les tables source créées ensuite) + les tables de capture.
-- Toutes les tables partagent la même structure :
--   id          identité technique
--   run_id      run Airflow qui a produit la capture
--   ingested_at horodatage d'insertion
--   source_key  clé d'origine (endpoint API / URL / colonne source selon le flux)
--   donnee      payload brut JSONB, tel que reçu

CREATE SCHEMA IF NOT EXISTS source;

GRANT USAGE ON SCHEMA source TO app_python;

ALTER DEFAULT PRIVILEGES IN SCHEMA source
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO app_python;

-- idPoste : capture du CSV conum téléchargé depuis S3.
CREATE TABLE source.idposte__conum (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- coop-numerique : structures, utilisateurs et activités reçus de l'API.
CREATE TABLE source.coop__structures (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

CREATE TABLE source.coop__utilisateurs (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

CREATE TABLE source.coop__activites (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- Aidants Connect : structures et aidants reçus de l'API.
-- Note : le fetch aidants est incrémental → ac__aidants capture le delta du run.
CREATE TABLE source.ac__structures (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

CREATE TABLE source.ac__aidants (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- Zonages : fichiers FRR et QPV téléchargés.
CREATE TABLE source.frr__zonage (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

CREATE TABLE source.qpv__zonage (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- Carto : fichier national mergé mednum-cli, avant enrichissement / déduplication.
-- source_key = valeur de la colonne "source" de chaque ligne (origine par ligne :
-- data-inclusion / coop), pas l'URL du dépôt.
CREATE TABLE source.carto__structures (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- SIRENE (INSEE) : brut renvoyé par l'API, au plus près de l'appel, avant parsing.
-- 1 ligne = 1 établissement brut ; source_key = endpoint INSEE appelé.
CREATE TABLE source.sirene__etablissements (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

-- BAN (IGN/Géoplateforme) : brut renvoyé par l'API, avant le filtre INSEE/score.
-- 1 ligne = 1 ligne CSV résultat brute ; source_key = URL appelée.
CREATE TABLE source.ban__adresses (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);
