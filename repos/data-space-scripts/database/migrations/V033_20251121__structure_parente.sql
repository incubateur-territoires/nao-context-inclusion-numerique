DROP VIEW dataviz.structures;

ALTER TABLE main.structure DROP COLUMN structure_parente;

CREATE OR REPLACE VIEW dataviz.structures AS (
    SELECT
        structure.*,
        adresse.clef_interop AS addr_clef_interop,
        adresse.code_ban AS addr_code_ban,
        adresse.departement AS addr_departement,
        adresse.code_postal AS addr_code_postal,
        adresse.code_insee AS addr_code_insee,
        adresse.nom_commune AS addr_nom_commune,
        adresse.nom_voie AS addr_nom_voie,
        adresse.repetition AS addr_repetition,
        adresse.numero_voie AS addr_numero_voie,
        coll_terr.region_code AS coll_terr_region_code,
        coll_terr.region_nom AS coll_terr_region_nom,
        coll_terr.departement_code AS coll_terr_departement_code,
        coll_terr.departement_nom AS coll_terr_departement_nom,
        coll_terr.code_insee AS coll_terr_code_insee,
        coll_terr.commune_nom AS coll_terr_commune_nom,
        categories_juridiques.nom AS categories_juridiques_nom,
        zonage.type AS zonage_type,
        zonage.code AS zonage_code,
        zonage.libelle AS zonage_libelle,
        zonage.commentaire AS zonage_complement,
        st_y(adresse.geom) AS addr_latitude,
        st_x(adresse.geom) AS addr_longitude
    FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
    LEFT JOIN admin.zonage ON (type = 'FRR' AND adresse.code_insee = zonage.code_insee) OR (type = 'QPV' AND st_contains(zonage.geom, adresse.geom))
);

COMMENT ON COLUMN main.adresse.departement IS 'Code département, généré à partir du code_insee';
