-- Silver du flux Aidants Connect quotidien (fiche 01 approche-data, étape 4
-- de la feuille de route) : les états transformés du run sortent de XCom vers
-- le schéma staging. Tables reconstruites à chaque run (TRUNCATE + INSERT),
-- 100 % re-dérivables depuis la capture brute source.ac__* + etl/core/ac.py.
--
--   staging.ac__aidants     aidants transformés du run (fetch incrémental → delta du run)
--   staging.ac__structures  structures transformées du run (stock complet)
--
-- Remplace le landing import.ac_* (V095) : pseudo-silver tout-TEXT écrit en
-- branche dead-end, sans lecteur — supprimé ci-dessous.
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

-- Sortie de etl.core.ac.transformer_aidants (colonnes AC_AIDANTS_IMPORT_COLS).
-- updated_at_ac sans timezone : parse_timestamp produit une chaîne UTC naïve,
-- même convention que main.personne.updated_at_ac.
CREATE TABLE staging.ac__aidants (
    run_id                TEXT        NOT NULL,
    staged_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    aidant_connect_id     BIGINT,
    updated_at_ac         TIMESTAMP,
    prenom                TEXT,
    nom                   TEXT,
    is_active_ac          BOOLEAN,
    formation_fne_ac      BOOLEAN,
    profession_ac         TEXT,
    nb_accompagnements_ac INTEGER,
    is_referent_ac        BOOLEAN,
    structure_ac_id       TEXT
);

-- Sortie de etl.core.ac.transformer_structures (colonnes AC_STRUCTURES_IMPORT_COLS).
-- dispositif_programmes_nationaux : littéral array PostgreSQL produit par
-- to_pg_array (ex. '{France Services}'), conservé tel quel.
CREATE TABLE staging.ac__structures (
    run_id                          TEXT        NOT NULL,
    staged_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
    structure_ac_id                 TEXT,
    updated_at_ac                   TIMESTAMP,
    is_active_ac                    BOOLEAN,
    nom                             TEXT,
    siret                           TEXT,
    nom_commune                     TEXT,
    code_postal                     TEXT,
    code_insee                      TEXT,
    adresse                         TEXT,
    nb_mandats_ac                   INTEGER,
    dispositif_programmes_nationaux TEXT
);

-- Landing V095 remplacé par le silver ci-dessus (mêmes colonnes, typées, et
-- désormais sur le chemin porteur du DAG au lieu d'une branche dead-end).
DROP TABLE IF EXISTS import.ac_aidants;
DROP TABLE IF EXISTS import.ac_structures;
