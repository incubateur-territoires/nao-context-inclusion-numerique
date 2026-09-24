-- Silver du flux coop-numerique (fiche 01 approche-data) : les états
-- transformés du run sortent des CSV du working_dir (effacés à chaque run)
-- vers le schéma staging. Tables reconstruites à chaque run (TRUNCATE +
-- INSERT), 100 % re-dérivables depuis la capture brute source.coop__* +
-- etl/core/coop.py.
--
--   staging.coop__structures    structures transformées du run (stock complet,
--                               hors structures portées par la carto nationale)
--   staging.coop__utilisateurs  utilisateurs transformés du run (stock complet)
--   staging.coop__activites     activités transformées du run (fetch incrémental
--                               -> delta du run)
--
-- Les colonnes portant du JSON (contact, personne_affectations,
-- coordination_mediation, beneficiaires) restent en TEXT : c'est la forme
-- produite par le core et castée ::jsonb par les ingests — inchangé.
-- Les littéraux pg-array du core (to_pg_array : '{a,b}') restent en TEXT,
-- castés ::text[] à l'ingest — inchangé.
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

-- Sortie de etl.core.coop.transformer_structures.
CREATE TABLE staging.coop__structures (
    run_id                          TEXT        NOT NULL,
    staged_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
    structure_coop_id               TEXT,
    updated_at_coop                 TIMESTAMP,
    deleted_at_coop                 TIMESTAMP,
    nom                             TEXT,
    siret                           TEXT,
    adresse                         TEXT,
    latitude                        DOUBLE PRECISION,
    longitude                       DOUBLE PRECISION,
    code_insee                      TEXT,
    code_postal                     TEXT,
    commune                         TEXT,
    rna                             TEXT,
    contact                         TEXT,
    typologies                      TEXT,
    presentation_resume             TEXT,
    presentation_detail             TEXT,
    horaires                        TEXT,
    prise_rdv                       TEXT,
    services                        TEXT,
    publics_specifiquement_adresses TEXT,
    prise_en_charge_specifique      TEXT,
    frais_a_charge                  TEXT,
    dispositif_programmes_nationaux TEXT,
    formations_labels               TEXT,
    autres_formations_labels        TEXT,
    itinerance                      TEXT,
    modalites_acces                 TEXT,
    modalites_accompagnement        TEXT,
    mediateurs_en_activite          INTEGER,
    emplois                         INTEGER,
    source                          TEXT
);

-- Sortie de etl.core.coop.transformer_utilisateurs.
CREATE TABLE staging.coop__utilisateurs (
    run_id                  TEXT        NOT NULL,
    staged_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    coop_id                 TEXT,
    updated_at_coop         TIMESTAMP,
    deleted_at_coop         TIMESTAMP,
    nom                     TEXT,
    prenom                  TEXT,
    contact                 TEXT,
    cn_pg_id                BIGINT,
    is_visible              BOOLEAN,
    conseiller_numerique_id TEXT,
    is_mediateur            BOOLEAN,
    is_coordinateur         BOOLEAN,
    personne_affectations   TEXT,
    coordination_mediation  TEXT
);

-- Sortie de etl.core.coop.transformer_activites.
CREATE TABLE staging.coop__activites (
    run_id                         TEXT        NOT NULL,
    staged_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    coop_id                        TEXT,
    mediateur_coop_id              TEXT,
    structure_coop_id              TEXT,
    type                           TEXT,
    date                           DATE,
    duree                          INTEGER,
    lieu_code_insee                TEXT,
    type_lieu                      TEXT,
    autonomie                      TEXT,
    structure_de_redirection       TEXT,
    oriente_vers_structure         BOOLEAN,
    precisions_demarche            TEXT,
    degre_de_finalisation_demarche TEXT,
    titre_atelier                  TEXT,
    niveau_atelier                 TEXT,
    accompagnements                INTEGER,
    thematiques                    TEXT,
    materiels                      TEXT,
    beneficiaires                  TEXT,
    created_at_coop                TIMESTAMP,
    updated_at_coop                TIMESTAMP
);
