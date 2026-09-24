-- Landing brut Aidants Connect : recréation des tables import.ac_structures et
-- import.ac_aidants alignées sur la sortie de _transform_data() du connecteur
-- (etl/extract/connectors/http_airflow.py, branches "aidants-structures" /
-- "aidants-personnes").
--
-- Les définitions historiques (V001) suivaient la forme brute de l'API AC
-- (id, name, zip_code, city_code, legal_category…) et n'étaient plus alimentées
-- depuis la refonte du DAG en flux XCom : tables mortes (0 ligne, référencées
-- nulle part dans le code).
--
-- Choix : colonnes TOUTES en TEXT. C'est une couche "raw / bronze" : on ingère
-- la donnée source sans coercition de type ni contrainte de longueur, pour ne
-- jamais faire échouer le COPY (cf. crash StringDataRightTruncation varchar(5)
-- côté main.adresse). Le typage et la validation restent à la charge des étapes
-- d'enrichissement / d'ingestion aval.

DROP TABLE IF EXISTS import.ac_structures;
CREATE TABLE import.ac_structures (
    structure_ac_id                 text,
    updated_at_ac                   text,
    is_active_ac                    text,
    nom                             text,
    siret                           text,
    nom_commune                     text,
    code_postal                     text,
    code_insee                      text,
    adresse                         text,
    nb_mandats_ac                   text,
    dispositif_programmes_nationaux text
);

DROP TABLE IF EXISTS import.ac_aidants;
CREATE TABLE import.ac_aidants (
    aidant_connect_id     text,
    updated_at_ac         text,
    prenom                text,
    nom                   text,
    is_active_ac          text,
    formation_fne_ac      text,
    profession_ac         text,
    nb_accompagnements_ac text,
    is_referent_ac        text,
    structure_ac_id       text
);
