CREATE OR REPLACE VIEW dataviz.zonages AS (
    WITH adresses AS (
        SELECT adresse.id AS adresse_id, adresse.code_insee, 
        CASE WHEN MAX(zone_qpv.id) > 0 THEN True ELSE False END AS qpv,
        CASE WHEN MAX(zone_frr.id) > 0 THEN True ELSE False END AS frr
        FROM main.adresse
        LEFT JOIN admin.zonage AS zone_qpv ON ST_Contains(zone_qpv.geom, adresse.geom) AND zone_qpv.type = 'QPV'
        LEFT JOIN admin.zonage AS zone_frr ON zone_frr.code_insee = adresse.code_insee AND zone_frr.type = 'FRR'
        GROUP BY adresse.id
        HAVING MAX(zone_qpv.id) > 0 OR MAX(zone_frr.id) > 0
    ),
    structures AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        COUNT(*) AS nbr
        FROM main.structure
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        GROUP BY adresse.code_insee
    ),
    lieux AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        COUNT(*) AS nbr
        FROM main.structure
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        AND visible_pour_cartographie_nationale
        GROUP BY adresse.code_insee
    ),
    activites AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        SUM(accompagnements) AS nbr
        FROM main.activites_coop
        INNER JOIN main.structure ON structure.id = activites_coop.structure_id
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        WHERE visible_pour_cartographie_nationale
        GROUP BY adresse.code_insee
    ),
    activites_conum AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        SUM(accompagnements) AS nbr
        FROM main.activites_coop
        INNER JOIN main.structure ON structure.id = activites_coop.structure_id
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        INNER JOIN main.personne ON personne.id = activites_coop.personne_id
        WHERE visible_pour_cartographie_nationale
        AND personne.conseiller_numerique_id IS NOT NULL
        GROUP BY adresse.code_insee
    ),
    personnes AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        COUNT(DISTINCT aff.personne_id) AS nbr
        FROM main.personne_affectations aff
        INNER JOIN main.structure ON structure.id = aff.structure_id
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        WHERE visible_pour_cartographie_nationale
        AND aff.type = 'lieu_activite' AND aff.suppression IS NULL
        GROUP BY adresse.code_insee
    ),
    personnes_conum AS (
        SELECT adresse.code_insee, 
        CASE 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) = 0 THEN 'QPV' 
            WHEN MAX(adresse.qpv::int) = 0 AND MAX(adresse.frr::int) > 0 THEN 'FRR' 
            WHEN MAX(adresse.qpv::int) > 0 AND MAX(adresse.frr::int) > 0 THEN 'QPV & FRR' 
        END AS zonage, 
        COUNT(DISTINCT aff.personne_id) AS nbr
        FROM main.personne_affectations aff
        INNER JOIN main.structure ON structure.id = aff.structure_id
        INNER JOIN adresses AS adresse ON adresse.adresse_id = structure.adresse_id
        INNER JOIN main.personne ON personne.id = aff.personne_id
        WHERE visible_pour_cartographie_nationale
        AND aff.type = 'lieu_activite' AND aff.suppression IS NULL
        AND personne.conseiller_numerique_id IS NOT NULL
        GROUP BY adresse.code_insee
    ),
    zonages AS (
        SELECT * FROM (VALUES ('QPV'), ('FRR'), ('QPV & FRR')) AS t(zonage)
    )
    SELECT region_nom AS region, departement_code AS code_departement, departement_nom AS departement, coll_terr.code_insee, commune_nom AS commune, zonages.zonage, 
        structures.nbr AS nbr_structures, 
        lieux.nbr AS nbr_lieux, 
        activites.nbr AS nbr_accompagnements,
        activites_conum.nbr AS nbr_accompagnements_conum,
        personnes.nbr AS nbr_personnes,
        personnes_conum.nbr AS nbr_conseillers_numerique
    FROM admin.coll_terr
    CROSS JOIN zonages
    LEFT JOIN structures ON structures.code_insee = coll_terr.code_insee AND structures.zonage = zonages.zonage
    LEFT JOIN lieux ON lieux.code_insee = coll_terr.code_insee AND lieux.zonage = zonages.zonage
    LEFT JOIN activites ON activites.code_insee = coll_terr.code_insee AND activites.zonage = zonages.zonage
    LEFT JOIN activites_conum ON activites_conum.code_insee = coll_terr.code_insee AND activites_conum.zonage = zonages.zonage
    LEFT JOIN personnes ON personnes.code_insee = coll_terr.code_insee AND personnes.zonage = zonages.zonage
    LEFT JOIN personnes_conum ON personnes_conum.code_insee = coll_terr.code_insee AND personnes_conum.zonage = zonages.zonage
    WHERE structures.nbr IS NOT NULL OR lieux.nbr IS NOT NULL OR activites.nbr IS NOT NULL OR activites_conum.nbr IS NOT NULL OR personnes.nbr IS NOT NULL OR personnes_conum.nbr IS NOT NULL
    GROUP BY region_nom, departement_code, departement_nom, coll_terr.code_insee, commune_nom, zonages.zonage, structures.nbr, lieux.nbr, activites.nbr, activites_conum.nbr, personnes.nbr, personnes_conum.nbr
    ORDER BY departement_code, coll_terr.code_insee, zonages.zonage
);

COMMENT ON VIEW dataviz.zonages IS 'Données pour la visualisation des zonages';
COMMENT ON COLUMN dataviz.zonages.zonage IS 'Type de zone : QPV (uniquement), FRR (uniquement) ou QPV ET FRR. (QPV: Quartier Prioritaire de la Ville, FRR: France Ruralités Revitalisation)';
COMMENT ON COLUMN dataviz.zonages.nbr_structures IS 'Nombre de structures employeuses situées dans le(s) zonage(s) concerné(s)';
COMMENT ON COLUMN dataviz.zonages.nbr_lieux IS 'Nombre de lieux d''activité situées dans le(s) zonage(s) concerné(s)';
COMMENT ON COLUMN dataviz.zonages.nbr_accompagnements IS 'Nombre total d''accompagnements';
COMMENT ON COLUMN dataviz.zonages.nbr_accompagnements_conum IS 'Nombre total d''accompagnements par des conseillers numériques';
COMMENT ON COLUMN dataviz.zonages.nbr_personnes IS 'Nombre de personnes intervenant dans ces lieux d''activité.';
COMMENT ON COLUMN dataviz.zonages.nbr_conseillers_numerique IS 'Nombre de conseillers numériques intervenant dans ces lieux d''activité.';
