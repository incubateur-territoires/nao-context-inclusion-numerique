CREATE VIEW dataviz.lieux_inclusion_numerique AS (
WITH
-- coordinateurs AS (
--     SELECT structure_id, COUNT(*) AS nbr
--     FROM main.personne
--     INNER JOIN main.personne_affectations AS e ON e.personne_id = personne.id AND type = 'structure_emploi'
--     WHERE is_coordinateur IS True AND suppression IS NULL
--     GROUP BY structure_id
-- ),
conseillers AS (
    SELECT
        personne.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND suppression IS NULL
    GROUP BY personne.structure_id
),

lieux AS (
    SELECT structure_id
    FROM main.personne_affectations
    WHERE type = 'lieu_activite' AND suppression IS NULL
    GROUP BY structure_id
)

SELECT
    structure.nom AS nom_structure,
    structure.siret,
    structure.rna,
    -- structure.code_activite_principale AS code_NAF_activite_principale,
    -- structure.denomination_sirene AS denomination_SIRENE_de_la_structure,
    categories_juridiques.nom AS "catégorie_juridique_de_la_structure",
    structure.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie)::text AS adresse,
    presentation_resume::text AS "présentation_résumée",
    -- adresse.code_insee AS code_insee_de_la_commune,
    presentation_detail::text AS "présentation_détaillée",
    horaires AS horaires_accueil,
    -- CASE WHEN personne_lieux_activites.id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "lieux_de_médiation_numérique",
    -- CASE WHEN structure_ac_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "employeur_aidants_connect",
    array_to_string(services, ', ')::text AS "services_proposés",
    -- nb_mandats_ac::integer AS "mandats_aidants_connect",
    array_to_string(dispositif_programmes_nationaux, ', ')::text AS dispositifs_nationaux,
    array_to_string(formations_labels || nullif(nullif(nullif(autres_formations_labels, '{ZRR}'), '{QPV}'), '{QPV,ZRR}'), ', ')::text AS formations,
    array_to_string(itinerance, ', ')::text AS "itinérance",
    array_to_string(modalites_acces, ', ')::text AS "modalités_accès",
    array_to_string(modalites_accompagnement, ', ')::text AS "modalités_accompagnement",
    mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    array_to_string(typologies, ', ') AS typologies,
    CASE WHEN zonage.type = 'QPV' THEN zonage.libelle ELSE 'Non' END AS qpv,
    CASE WHEN zonage.type = 'FRR' THEN 'Oui' ELSE 'Non' END AS frr,
    CASE WHEN structure.structure_coop_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "employeur_conseiller_numérique",
    -- coordinateurs.nbr AS nombre_de_coordinateurs,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
FROM main.structure
LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
LEFT JOIN admin.zonage ON (type = 'FRR' AND adresse.code_insee = zonage.code_insee) OR (type = 'QPV' AND st_contains(zonage.geom, adresse.geom))
-- LEFT JOIN coordinateurs ON coordinateurs.structure_id = structure.id
LEFT JOIN conseillers ON structure.id = conseillers.structure_id
INNER JOIN lieux ON structure.id = lieux.structure_id
);

COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.nom_structure IS 'Nom de la structure';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.siret IS 'Code SIRET de la structure. https://annuaire-entreprises.data.gouv.fr/';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.rna IS 'Identifiant du Répertoire National des Associations (RNA)';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."état_administratif_de_la_structure" IS 'État administratif de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."catégorie_juridique_de_la_structure" IS 'Catégorie juridique de l''INSEE';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.typologies IS 'Type de structure';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.frr IS 'Présence de la structure dans une zone France Ruralités Revitalisation';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.qpv IS 'Présence de la structure dans un Quartier Prioritaire de la Ville';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.dispositifs_nationaux IS 'Appartenance à un dispositif ou à un programme national';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.formations IS 'Formations et labels de la structure';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."itinérance" IS 'Caractère itinérant du lieu (bus numérique, cyber-caravane, camion connecté...)';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."modalités_accès" IS 'Différentes étapes ou démarches à suivre pour se rendre au lieu d''inclusion numérique et bénéficier de ses services.';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."modalités_accompagnement" IS 'Types d''accompagnement proposés par le lieu. (En autonomie, Accompagnement individuel, Atelier collectif...)';


CREATE VIEW dataviz.structures_employeuses AS (
WITH coordinateurs AS (
    SELECT
        personne.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE is_coordinateur IS TRUE AND suppression IS NULL
    GROUP BY personne.structure_id
),

conseillers AS (
    SELECT
        personne.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND suppression IS NULL
    GROUP BY personne.structure_id
),

aidants_connect AS (
    SELECT
        personne.structure_id,
        sum(personne.nb_accompagnements_ac) AS nbr
    FROM main.personne
    INNER JOIN main.structure ON personne.structure_id = structure.id AND structure.structure_ac_id IS NOT NULL
    GROUP BY personne.structure_id
),

coop AS (
    SELECT
        structure_id,
        count(*) AS nbr
    FROM main.activites_coop
    INNER JOIN main.structure ON activites_coop.structure_id = structure.id AND structure.structure_coop_id IS NOT NULL
    GROUP BY structure_id
)

SELECT
    structure.nom AS nom_structure,
    structure.siret,
    structure.rna,
    structure.code_activite_principale AS code_naf,
    categories_juridiques.nom AS "catégorie_juridique_de_la_structure",
    structure.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie)::text AS adresse,
    array_to_string(dispositif_programmes_nationaux, ', ')::text AS dispositifs_nationaux,
    mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coordinateurs.nbr AS nombre_de_coordinateurs,
    nb_mandats_ac::integer AS mandats_aidants_connect,
    aidants_connect.nbr AS accompagnements_aidants_connect,
    coop.nbr AS "nombre_accompagnements_médiateurs_numériques",
    array_to_string(typologies, ', ') AS typologies,
    CASE WHEN structure_ac_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS employeur_aidants_connect,
    CASE WHEN structure.structure_coop_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
FROM main.structure
LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
LEFT JOIN coordinateurs ON structure.id = coordinateurs.structure_id
LEFT JOIN conseillers ON structure.id = conseillers.structure_id
LEFT JOIN aidants_connect ON structure.id = aidants_connect.structure_id
LEFT JOIN coop ON structure.id = coop.structure_id
);

COMMENT ON COLUMN dataviz.structures_employeuses.nom_structure IS 'Nom de la structure';
COMMENT ON COLUMN dataviz.structures_employeuses.siret IS 'Code SIRET de la structure. https://annuaire-entreprises.data.gouv.fr/';
COMMENT ON COLUMN dataviz.structures_employeuses.rna IS 'Identifiant du Répertoire National des Associations (RNA)';
COMMENT ON COLUMN dataviz.structures_employeuses.code_naf IS 'Code NAF de l''activité principale (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."état_administratif_de_la_structure" IS 'Etat administratif de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."catégorie_juridique_de_la_structure" IS 'Catégorie juridique de l''INSEE';
COMMENT ON COLUMN dataviz.structures_employeuses.typologies IS 'Type de structure';
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.dispositifs_nationaux IS 'Appartenance à un dispositif ou à un programme national';


CREATE VIEW dataviz.personne AS (
    WITH lieux AS (
        SELECT
personne_id,
            count(*) AS nbr
        FROM main.personne_affectations
        WHERE type = 'lieu_activite'
        GROUP BY personne_id
    ),

coop AS (
        SELECT
personne_id,
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
CREATE VIEW dataviz.personne_pseudonymisee AS (
    WITH lieux AS (
        SELECT
personne_id,
            count(*) AS nbr
        FROM main.personne_affectations
        WHERE type = 'lieu_activite'
        GROUP BY personne_id
    ),

coop AS (
        SELECT
personne_id,
            count(*) AS nbr
        FROM main.activites_coop
        GROUP BY personne_id
    )

SELECT
    CASE WHEN conseiller_numerique_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "Conseiller Numérique",
    CASE WHEN is_coordinateur IS True THEN 'Oui' WHEN is_coordinateur IS False THEN 'Non' ELSE Null END AS "Coordinateur",
    CASE WHEN is_active_ac IS True THEN 'Oui' WHEN is_active_ac IS False THEN 'Non' ELSE Null END AS "Aidants Connect",
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
