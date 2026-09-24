DROP VIEW dataviz.personne;

CREATE VIEW dataviz.personne AS (
    WITH lieux AS (
        SELECT lieux.personne_id, MIN(qpv.id) AS qpv, MIN(frr.id) AS frr, COUNT(*) AS nbr
        FROM main.personne_affectations AS lieux 
        INNER JOIN main.structure ON structure.id = lieux.structure_id
        INNER JOIN main.adresse ON adresse.id = structure.adresse_id
        LEFT JOIN admin.zonage AS qpv ON qpv.type = 'QPV' AND ST_Contains(qpv.geom, adresse.geom)
        LEFT JOIN admin.zonage AS frr ON frr.type = 'FRR' AND adresse.code_insee = frr.code_insee
        WHERE lieux.type = 'lieu_activite'
        GROUP BY personne_id
    ),

    coop AS (
            SELECT personne_id,
                count(*) AS nbr
            FROM main.activites_coop
            GROUP BY personne_id
        )

    SELECT
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    personne.contact -> 'telephone' AS "Téléphone",
    concat_ws(', ', personne.contact -> 'courriels' ->> 'mail_pro', personne.contact -> 'courriels' ->> 'mail_perso')::text AS emails,
    
    CASE WHEN conseiller_numerique_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "Conseiller Numérique",
    CASE WHEN is_coordinateur IS True THEN 'Oui' WHEN is_coordinateur IS False THEN 'Non' ELSE Null END AS "Coordinateur",
    CASE WHEN is_active_ac IS True THEN 'Oui' WHEN is_active_ac IS False THEN 'Non' ELSE Null END AS "Aidants Connect",
    
    CASE
        WHEN (personne.is_mediateur = true) THEN 'Médiateur'::text
        WHEN ((personne.is_mediateur = false) OR (personne.is_mediateur IS NULL)) THEN 'Aidant numérique'::text
        ELSE NULL::text
    END AS "Type accompagnateur",

    CASE WHEN is_active_ac IS True OR (SELECT CASE WHEN MIN(pa.id) IS NOT NULL THEN true ELSE false END FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.type = 'structure_emploi' AND pa.suppression IS NULL) THEN 'Oui' ELSE 'Non' END AS "En poste",

    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "FRR",

    lieux.nbr AS "Lieux activités",
    structure.nom AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    coll_terr.commune_nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0), 0) AS nombre_accompagnements_totaux,
    formation.label AS "Formation",
    formation.date_debut AS "date de début",
    formation.date_fin AS "date de fin",
    CASE WHEN formation.pix IS True THEN 'Oui' WHEN formation.pix IS False THEN 'Non' ELSE Null END AS "Certification PIX",
    CASE WHEN formation.remn IS True THEN 'Oui' WHEN formation.remn IS False THEN 'Non' ELSE Null END AS "Certification REMN"
    FROM main.personne
    LEFT JOIN main.personne_affectations ON personne.id = personne_affectations.personne_id AND type = 'structure_emploi'
    LEFT JOIN main.structure ON personne_affectations.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id
    );


-- Vue Personne pseudonymisée
-- Même vue que ci-dessus, mais sans les colonnes personne.nom, personne.prenom, personne.contact
DROP VIEW dataviz.personne_pseudonymisee;

CREATE VIEW dataviz.personne_pseudonymisee AS (
    WITH lieux AS (
        SELECT lieux.personne_id, MIN(qpv.id) AS qpv, MIN(frr.id) AS frr, COUNT(*) AS nbr
        FROM main.personne_affectations AS lieux 
        INNER JOIN main.structure ON structure.id = lieux.structure_id
        INNER JOIN main.adresse ON adresse.id = structure.adresse_id
        LEFT JOIN admin.zonage AS qpv ON qpv.type = 'QPV' AND ST_Contains(qpv.geom, adresse.geom)
        LEFT JOIN admin.zonage AS frr ON frr.type = 'FRR' AND adresse.code_insee = frr.code_insee
        WHERE lieux.type = 'lieu_activite'
        GROUP BY personne_id
    ),

    coop AS (
        SELECT personne_id, count(*) AS nbr
        FROM main.activites_coop
        GROUP BY personne_id
    )
    SELECT
    CASE WHEN conseiller_numerique_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "Conseiller Numérique",
    CASE WHEN is_coordinateur IS True THEN 'Oui' WHEN is_coordinateur IS False THEN 'Non' ELSE Null END AS "Coordinateur",
    CASE WHEN is_active_ac IS True THEN 'Oui' WHEN is_active_ac IS False THEN 'Non' ELSE Null END AS "Aidants Connect",
    CASE
        WHEN (personne.is_mediateur = true) THEN 'Médiateur'::text
        WHEN ((personne.is_mediateur = false) OR (personne.is_mediateur IS NULL)) THEN 'Aidant numérique'::text
        ELSE NULL::text
    END AS "Type accompagnateur",
    CASE WHEN is_active_ac IS True OR (SELECT CASE WHEN MIN(pa.id) IS NOT NULL THEN true ELSE false END FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.type = 'structure_emploi' AND pa.suppression IS NULL) THEN 'Oui' ELSE 'Non' END AS "En poste",
    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "FRR",
    lieux.nbr AS "Lieux activités",
    structure.nom AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    coll_terr.commune_nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0), 0) AS nombre_accompagnements_totaux,
    formation.label AS "Formation",
    formation.date_debut AS "date de début",
    formation.date_fin AS "date de fin",
    formation.pix AS "Certification PIX",
    formation.remn AS "Certification REMN"
    FROM main.personne
    LEFT JOIN main.personne_affectations ON personne.id = personne_affectations.personne_id AND type = 'structure_emploi'
    LEFT JOIN main.structure ON personne_affectations.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id
    );
