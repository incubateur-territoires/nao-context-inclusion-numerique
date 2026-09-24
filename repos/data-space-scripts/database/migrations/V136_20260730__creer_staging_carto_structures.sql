-- Silver du flux carto (cartographie nationale, fichier national dédupliqué
-- mednum-cli) : l'état transformé du run (sortie de transformer_lieux —
-- etl/core/carto.py) est matérialisé dans staging au lieu de la table de
-- landing legacy import.carto. TRUNCATE + INSERT à chaque run, relu filtré
-- sur run_id par integration_adresses / integration_lieux.
--
-- Par rapport à import.carto, la table ne porte plus :
--   - les 13 colonnes mortes (adresse_sirene, etat_administratif,
--     code_activite_principale, categorie_juridique, denomination_sirene,
--     ban_*) : NULL à 100 % depuis la bascule sur le fichier national, qui
--     ne les contient pas ;
--   - structure_parente : jamais chargée (absente de DTYPE_CARTO) ;
--   - lieu_inclusion_id : le backfill portait la SEULE FK import → main de
--     toute la base. L'association est déjà donnée par
--     main.lieu_inclusion.structure_cartographie_nationale_id = id — le
--     silver reste en sens unique (bronze → silver → gold, aucune FK,
--     aucun write-back).
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

CREATE TABLE staging.carto__structures (
    run_id                          TEXT        NOT NULL,
    staged_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
    id                              TEXT        NOT NULL,
    structure_coop_id               UUID,
    pivot                           TEXT        NOT NULL,
    nom                             TEXT        NOT NULL,
    commune                         TEXT        NOT NULL,
    code_postal                     TEXT        NOT NULL,
    code_insee                      TEXT,
    adresse                         TEXT        NOT NULL,
    complement_adresse              TEXT,
    latitude                        REAL,
    longitude                       REAL,
    typologie                       TEXT,
    telephone                       TEXT,
    courriels                       TEXT,
    site_web                        TEXT,
    horaires                        TEXT,
    presentation_resume             TEXT,
    presentation_detail             TEXT,
    source                          TEXT,
    itinerance                      TEXT,
    date_maj                        DATE        NOT NULL,
    services                        TEXT,
    publics_specifiquement_adresses TEXT,
    prise_en_charge_specifique      TEXT,
    frais_a_charge                  TEXT,
    dispositif_programmes_nationaux TEXT,
    formations_labels               TEXT,
    autres_formations_labels        TEXT,
    modalites_acces                 TEXT,
    modalites_accompagnement        TEXT,
    fiche_acces_libre               TEXT,
    prise_rdv                       TEXT
);

-- La table de landing legacy n'a plus ni producteur ni lecteur. Sa FK
-- carto_lieu_inclusion_id_fkey (unique lien import → main) part avec elle.
DROP TABLE import.carto;
