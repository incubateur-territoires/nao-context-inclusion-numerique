-- ============================================================
-- V043 – Remplacer suppression par est_active,
--        supprimer is_active_ac de personne
-- ============================================================
BEGIN;

-- 1) Ajouter est_active, backfill depuis suppression
ALTER TABLE main.personne_affectations ADD COLUMN est_active BOOLEAN;
UPDATE main.personne_affectations SET est_active = (suppression IS NULL);
ALTER TABLE main.personne_affectations ALTER COLUMN est_active SET NOT NULL;
ALTER TABLE main.personne_affectations ALTER COLUMN est_active SET DEFAULT TRUE;

-- 2) UK1 dedup : garder 1 ligne par (personne_id, structure_id, type, source)
--    Priorite : garder l'active (est_active=TRUE), sinon la plus recente (id max)
DELETE FROM main.personne_affectations
WHERE id IN (
    SELECT id FROM (
        SELECT id,
            ROW_NUMBER() OVER (
                PARTITION BY personne_id, structure_id, type, source
                ORDER BY est_active DESC, id DESC
            ) AS rn
        FROM main.personne_affectations
    ) ranked
    WHERE rn > 1
);

-- 3) UK2 dedup : garder 1 ligne par (structure_coop_id, mediateur_coop_id, type)
DELETE FROM main.personne_affectations
WHERE id IN (
    SELECT id FROM (
        SELECT id,
            ROW_NUMBER() OVER (
                PARTITION BY structure_coop_id, mediateur_coop_id, type
                ORDER BY est_active DESC, id DESC
            ) AS rn
        FROM main.personne_affectations
        WHERE structure_coop_id IS NOT NULL AND mediateur_coop_id IS NOT NULL
    ) ranked
    WHERE rn > 1
);

-- 4) Supprimer les anciens index uniques et en creer de nouveaux
DROP INDEX IF EXISTS main.personne_affectations_ukey;
DROP INDEX IF EXISTS main.personne_affectations_unique_key;

CREATE UNIQUE INDEX personne_affectations_ukey
ON main.personne_affectations (structure_coop_id, mediateur_coop_id, type);

CREATE UNIQUE INDEX personne_affectations_unique_key
ON main.personne_affectations (structure_id, personne_id, type, source);

-- 5) Supprimer les vues dependantes avant de supprimer les colonnes
DROP MATERIALIZED VIEW IF EXISTS dataviz.personne_similarities;
DROP VIEW IF EXISTS dataviz.personne;
DROP VIEW IF EXISTS dataviz.personne_pseudonymisee;
DROP VIEW IF EXISTS dataviz.structures_employeuses;
DROP VIEW IF EXISTS dataviz.lieux_inclusion_numerique;
DROP VIEW IF EXISTS dataviz.zonages;
DROP VIEW IF EXISTS api.aidants_connect;
DROP VIEW IF EXISTS api.carto;
DROP VIEW IF EXISTS min.personne_enrichie;

-- 6) Supprimer les colonnes suppression et is_active_ac
ALTER TABLE main.personne_affectations DROP COLUMN suppression;
ALTER TABLE main.personne DROP COLUMN is_active_ac;

-- 7) Commentaire
COMMENT ON COLUMN main.personne_affectations.est_active IS
  'Indique si l affectation est en cours (TRUE) ou terminee (FALSE).';

-- ============================================================
-- 8) Redefinition des vues
-- ============================================================

-- --- dataviz.lieux_inclusion_numerique (V019) ---
CREATE VIEW dataviz.lieux_inclusion_numerique AS (
WITH
conseillers AS (
    SELECT
        e.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'lieu_activite'
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND e.est_active = TRUE
    GROUP BY e.structure_id
),
coop_lieu AS (
    SELECT
        structure_id,
        COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY structure_id
)

SELECT
    structure.id AS structure_id,
    structure.nom AS nom,
    structure.siret,
    structure.rna,
    categories_juridiques.nom AS "catégorie_juridique_de_la_structure",
    structure.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie)::text AS adresse,
    presentation_resume::text AS "présentation_résumée",
    presentation_detail::text AS "présentation_détaillée",
    horaires AS horaires_accueil,
    array_to_string(services, ', ')::text AS "services_proposés",
    array_to_string(dispositif_programmes_nationaux, ', ')::text AS dispositifs_nationaux,
    array_to_string(formations_labels || nullif(nullif(nullif(autres_formations_labels, '{ZRR}'), '{QPV}'), '{QPV,ZRR}'), ', ')::text AS formations,
    array_to_string(itinerance, ', ')::text AS "itinérance",
    array_to_string(modalites_acces, ', ')::text AS "modalités_accès",
    array_to_string(modalites_accompagnement, ', ')::text AS "modalités_accompagnement",
    mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coop_lieu.nbr AS "nombre_accompagnements",
    array_to_string(typologies, ', ') AS typologies,
    CASE WHEN zonage.type = 'QPV' THEN zonage.libelle ELSE 'Non' END AS qpv,
    CASE WHEN zonage.type = 'FRR' THEN 'Oui' ELSE 'Non' END AS frr,
    CASE WHEN 'France Services' = ANY(structure.dispositif_programmes_nationaux) THEN 'Oui' ELSE 'Non' END AS est_france_services,
    CASE WHEN structure.structure_coop_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
FROM main.structure
LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
LEFT JOIN admin.zonage ON (type = 'FRR' AND adresse.code_insee = zonage.code_insee) OR (type = 'QPV' AND st_contains(zonage.geom, adresse.geom))
LEFT JOIN conseillers ON structure.id = conseillers.structure_id
LEFT JOIN coop_lieu ON structure.id = coop_lieu.structure_id
WHERE structure.structure_cartographie_nationale_id IS NOT NULL
);

COMMENT ON COLUMN dataviz.lieux_inclusion_numerique.nom IS 'Nom de la structure';
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
COMMENT ON COLUMN dataviz.lieux_inclusion_numerique."nombre_accompagnements" IS 'Nombre total d''accompagnements enregistrés (Coop) pour ce lieu / structure.';


-- --- dataviz.structures_employeuses (V022) ---
CREATE VIEW dataviz.structures_employeuses AS (
WITH coordinateurs AS (
    SELECT
        e.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE is_coordinateur IS TRUE AND e.est_active = TRUE
    GROUP BY e.structure_id
),

conseillers AS (
    SELECT
        e.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND e.est_active = TRUE
    GROUP BY e.structure_id
),

aidants_connect AS (
    SELECT
        e.structure_id,
        COUNT(*) AS nbr_rattach,
        SUM(COALESCE(CASE WHEN s.structure_ac_id IS NOT NULL THEN p.nb_accompagnements_ac ELSE 0 END, 0)) AS nbr_accompagnements
    FROM main.personne AS p
    INNER JOIN main.personne_affectations AS e
        ON p.id = e.personne_id
       AND e.type = 'structure_emploi'
       AND e.est_active = TRUE
    LEFT JOIN main.structure s ON e.structure_id = s.id
    WHERE (
        EXISTS (
            SELECT 1 FROM main.personne_affectations pa
            WHERE pa.personne_id = p.id
              AND pa.source = 'aidants-connect'
              AND pa.est_active = TRUE
              AND pa.type = 'structure_emploi'
        )
        OR p.aidant_connect_id IS NOT NULL
    )
    GROUP BY e.structure_id
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
    structure.id AS structure_id,
    structure.nom AS nom,
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
    CASE WHEN zonage.type = 'QPV' THEN zonage.libelle ELSE 'Non' END AS qpv,
    CASE WHEN zonage.type = 'FRR' THEN 'Oui' ELSE 'Non' END AS frr,
    CASE WHEN COALESCE(conseillers.nbr, 0) > 0 THEN 'Oui' ELSE 'Non' END AS est_conum,
    CASE WHEN COALESCE(aidants_connect.nbr_rattach, 0) > 0 THEN 'Oui' ELSE 'Non' END AS est_aidant_connect,
    CASE WHEN 'France Services' = ANY(structure.dispositif_programmes_nationaux) THEN 'Oui' ELSE 'Non' END AS est_france_services,
    mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    aidants_connect.nbr_rattach AS nombre_aidants_connect,
    coordinateurs.nbr AS nombre_de_coordinateurs,
    nb_mandats_ac::integer AS mandats_aidants_connect,
    aidants_connect.nbr_accompagnements AS accompagnements_aidants_connect,
    coop.nbr AS "nombre_accompagnements_médiateurs_numériques",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
FROM main.structure
LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
LEFT JOIN admin.zonage ON (type = 'FRR' AND adresse.code_insee = zonage.code_insee) OR (type = 'QPV' AND st_contains(zonage.geom, adresse.geom))
LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
LEFT JOIN coordinateurs ON structure.id = coordinateurs.structure_id
LEFT JOIN conseillers ON structure.id = conseillers.structure_id
LEFT JOIN aidants_connect ON structure.id = aidants_connect.structure_id
LEFT JOIN coop ON structure.id = coop.structure_id
);

COMMENT ON COLUMN dataviz.structures_employeuses.nom IS 'Nom de la structure';
COMMENT ON COLUMN dataviz.structures_employeuses.siret IS 'Code SIRET de la structure. https://annuaire-entreprises.data.gouv.fr/';
COMMENT ON COLUMN dataviz.structures_employeuses.rna IS 'Identifiant du Répertoire National des Associations (RNA)';
COMMENT ON COLUMN dataviz.structures_employeuses.code_naf IS 'Code NAF de l''activité principale (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."état_administratif_de_la_structure" IS 'Etat administratif de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."catégorie_juridique_de_la_structure" IS 'Catégorie juridique de l''INSEE';
COMMENT ON COLUMN dataviz.structures_employeuses.est_conum IS 'Oui si au moins un Conseiller numérique est rattaché à la structure (conseillers.nbr > 0), sinon Non.';
COMMENT ON COLUMN dataviz.structures_employeuses.est_aidant_connect IS 'Oui si au moins un Aidant Connect est rattaché à la structure (affectations actives type ''structure_emploi'' ; aidants_connect.nbr_rattach > 0), sinon';
COMMENT ON COLUMN dataviz.structures_employeuses.est_france_services IS 'Oui si la structure est labellisée France Services, sinon';
COMMENT ON COLUMN dataviz.structures_employeuses.nombre_aidants_connect IS 'Nombre de personnes Aidants Connect rattachées à la structure (affectations actives type ''structure_emploi'').';
COMMENT ON COLUMN dataviz.structures_employeuses.accompagnements_aidants_connect IS 'Somme des accompagnements réalisés par les Aidants Connect de la structure (nb_accompagnements_ac).';


-- --- dataviz.personne (V019) ---
CREATE VIEW dataviz.personne AS (
    WITH lieux AS (
        SELECT lieux.personne_id, MIN(qpv.id) AS qpv, MIN(frr.id) AS frr, COUNT(*) AS nbr,
            CASE WHEN bool_or('France Services' = ANY(structure.dispositif_programmes_nationaux)) THEN 'Oui' ELSE 'Non' END AS est_france_services
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
    personne.id AS "Personne ID",
    structure.id AS "Structure employeuse ID",
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    personne.contact -> 'telephone' AS "Téléphone",
    concat_ws(', ', personne.contact -> 'courriels' ->> 'mail_pro', personne.contact -> 'courriels' ->> 'mail_perso')::text AS emails,

    CASE WHEN conseiller_numerique_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "Conseiller Numérique",
    CASE WHEN is_coordinateur IS True THEN 'Oui' WHEN is_coordinateur IS False THEN 'Non' ELSE Null END AS "Coordinateur",
    CASE
        WHEN EXISTS (SELECT 1 FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.source = 'aidants-connect' AND pa.est_active = TRUE AND pa.type = 'structure_emploi') THEN 'Oui'
        WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'
        ELSE Null
    END AS "Aidants Connect",

    CASE
        WHEN (personne.is_mediateur = true) THEN 'Médiateur'::text
        WHEN ((personne.is_mediateur = false) OR (personne.is_mediateur IS NULL)) THEN 'Aidant numérique'::text
        ELSE NULL::text
    END AS "Type accompagnateur",

    CASE WHEN EXISTS (SELECT 1 FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.type = 'structure_emploi' AND pa.est_active = TRUE) THEN 'Oui' ELSE 'Non' END AS "En poste",

    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "FRR",

    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    structure.nom AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0), 0) AS nombre_accompagnements_totaux,

    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui' ELSE 'Non' END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS True THEN 'Oui' WHEN formation.pix IS False THEN 'Non' ELSE Null END AS "Certification PIX",
    CASE WHEN formation.remn IS True THEN 'Oui' WHEN formation.remn IS False THEN 'Non' ELSE Null END AS "Certification REMN"
    FROM main.personne
    LEFT JOIN main.personne_affectations ON personne.id = personne_affectations.personne_id AND type = 'structure_emploi' AND personne_affectations.est_active = TRUE AND personne_affectations.structure_id IS NOT NULL
    LEFT JOIN main.structure ON personne_affectations.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.commune ON adresse.code_insee = commune.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id
    );


-- --- dataviz.personne_pseudonymisee (V019) ---
CREATE VIEW dataviz.personne_pseudonymisee AS (
    WITH lieux AS (
        SELECT lieux.personne_id, MIN(qpv.id) AS qpv, MIN(frr.id) AS frr, COUNT(*) AS nbr,
            CASE WHEN bool_or('France Services' = ANY(structure.dispositif_programmes_nationaux)) THEN 'Oui' ELSE 'Non' END AS est_france_services
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
    CASE WHEN conseiller_numerique_id IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "Conseiller Numérique",
    CASE WHEN is_coordinateur IS True THEN 'Oui' WHEN is_coordinateur IS False THEN 'Non' ELSE Null END AS "Coordinateur",
    CASE
        WHEN EXISTS (SELECT 1 FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.source = 'aidants-connect' AND pa.est_active = TRUE AND pa.type = 'structure_emploi') THEN 'Oui'
        WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'
        ELSE Null
    END AS "Aidants Connect",

    CASE
        WHEN (personne.is_mediateur = true) THEN 'Médiateur'::text
        WHEN ((personne.is_mediateur = false) OR (personne.is_mediateur IS NULL)) THEN 'Aidant numérique'::text
        ELSE NULL::text
    END AS "Type accompagnateur",

    CASE WHEN EXISTS (SELECT 1 FROM main.personne_affectations pa WHERE pa.personne_id = personne.id AND pa.type = 'structure_emploi' AND pa.est_active = TRUE) THEN 'Oui' ELSE 'Non' END AS "En poste",

    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "FRR",

    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    structure.nom AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0), 0) AS nombre_accompagnements_totaux,
    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui' ELSE 'Non' END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS True THEN 'Oui' WHEN formation.pix IS False THEN 'Non' ELSE Null END AS "Certification PIX",
    CASE WHEN formation.remn IS True THEN 'Oui' WHEN formation.remn IS False THEN 'Non' ELSE Null END AS "Certification REMN"
    FROM main.personne
    LEFT JOIN main.personne_affectations ON personne.id = personne_affectations.personne_id AND type = 'structure_emploi' AND personne_affectations.est_active = TRUE AND personne_affectations.structure_id IS NOT NULL
    LEFT JOIN main.structure ON personne_affectations.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.commune ON adresse.code_insee = commune.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id
    );


-- --- dataviz.zonages (V020) ---
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
        AND aff.type = 'lieu_activite' AND aff.est_active = TRUE
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
        AND aff.type = 'lieu_activite' AND aff.est_active = TRUE
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

COMMENT ON VIEW dataviz.zonages IS 'Données pour la visualisation des zonages';
COMMENT ON COLUMN dataviz.zonages.zonage IS 'Type de zone : QPV (uniquement), FRR (uniquement) ou QPV ET FRR. (QPV: Quartier Prioritaire de la Ville, FRR: France Ruralités Revitalisation)';
COMMENT ON COLUMN dataviz.zonages.nbr_structures IS 'Nombre de structures employeuses situées dans le(s) zonage(s) concerné(s)';
COMMENT ON COLUMN dataviz.zonages.nbr_lieux IS 'Nombre de lieux d''activité situées dans le(s) zonage(s) concerné(s)';
COMMENT ON COLUMN dataviz.zonages.nbr_accompagnements IS 'Nombre total d''accompagnements';
COMMENT ON COLUMN dataviz.zonages.nbr_accompagnements_conum IS 'Nombre total d''accompagnements par des conseillers numériques';
COMMENT ON COLUMN dataviz.zonages.nbr_personnes IS 'Nombre de personnes intervenant dans ces lieux d''activité.';
COMMENT ON COLUMN dataviz.zonages.nbr_conseillers_numerique IS 'Nombre de conseillers numériques intervenant dans ces lieux d''activité.';


-- --- dataviz.personne_similarities (V041, materialized) ---
CREATE MATERIALIZED VIEW dataviz.personne_similarities AS

WITH fusionnes AS (
    SELECT id
    FROM main.personne
    WHERE cn_pg_id IS NOT NULL
      AND aidant_connect_id IS NOT NULL
      AND coop_id IS NOT NULL
),

base AS (
    SELECT
        p.id,
        p.aidant_connect_id,
        p.cn_pg_id,
        p.coop_id,
        unaccent(lower(trim(p.nom)))     AS nom_n,
        unaccent(lower(trim(p.prenom)))  AS prenom_n,
        a.code_insee,
        COALESCE(p.updated_at, p.created_at) AS ts
    FROM main.personne p
    JOIN main.personne_affectations pa ON pa.personne_id = p.id
    JOIN main.structure s              ON s.id = pa.structure_id
    JOIN main.adresse a                ON a.id = s.adresse_id
    WHERE pa.est_active = TRUE
      AND pa.type = 'structure_emploi'
      AND p.nom IS NOT NULL
      AND p.prenom IS NOT NULL
      AND p.id NOT IN (SELECT id FROM fusionnes)
),

ac AS (
    SELECT * FROM base WHERE aidant_connect_id IS NOT NULL
),

cn AS (
    SELECT * FROM base WHERE cn_pg_id IS NOT NULL
),

coop AS (
    SELECT * FROM base WHERE coop_id IS NOT NULL
),

matchs_ac_cn AS (
    SELECT
        ac.id AS id_1,
        cn.id AS id_2,
        'AC_CN' AS match_type,
        ac.nom_n,
        ac.prenom_n,
        ac.code_insee,
        similarity(ac.nom_n, cn.nom_n) AS sim_nom,
        similarity(ac.prenom_n, cn.prenom_n) AS sim_prenom,
        ac.ts AS ts_1,
        cn.ts AS ts_2
    FROM ac
    JOIN cn
      ON ac.code_insee = cn.code_insee
     AND ac.id <> cn.id
     AND similarity(ac.nom_n, cn.nom_n) > 0
     AND similarity(ac.prenom_n, cn.prenom_n) > 0
),

matchs_ac_coop AS (
    SELECT
        ac.id AS id_1,
        coop.id AS id_2,
        'AC_COOP' AS match_type,
        ac.nom_n,
        ac.prenom_n,
        ac.code_insee,
        similarity(ac.nom_n, coop.nom_n) AS sim_nom,
        similarity(ac.prenom_n, coop.prenom_n) AS sim_prenom,
        ac.ts AS ts_1,
        coop.ts AS ts_2
    FROM ac
    JOIN coop
      ON ac.code_insee = coop.code_insee
     AND ac.id <> coop.id
     AND similarity(ac.nom_n, coop.nom_n) > 0
     AND similarity(ac.prenom_n, coop.prenom_n) > 0
),

matchs_cn_coop AS (
    SELECT
        cn.id AS id_1,
        coop.id AS id_2,
        'CN_COOP' AS match_type,
        cn.nom_n,
        cn.prenom_n,
        cn.code_insee,
        similarity(cn.nom_n, coop.nom_n) AS sim_nom,
        similarity(cn.prenom_n, coop.prenom_n) AS sim_prenom,
        cn.ts AS ts_1,
        coop.ts AS ts_2
    FROM cn
    JOIN coop
      ON cn.code_insee = coop.code_insee
     AND cn.id <> coop.id
     AND similarity(cn.nom_n, coop.nom_n) > 0
     AND similarity(cn.prenom_n, coop.prenom_n) > 0
),

all_matchs AS (
    SELECT * FROM matchs_ac_cn
    UNION ALL
    SELECT * FROM matchs_ac_coop
    UNION ALL
    SELECT * FROM matchs_cn_coop
)

SELECT DISTINCT ON (m.id_1, m.id_2)
    m.match_type,
    m.nom_n,
    m.prenom_n,
    m.code_insee,
    m.id_1,
    m.id_2,
    ROUND(m.sim_nom::numeric, 3) AS sim_nom,
    ROUND(m.sim_prenom::numeric, 3) AS sim_prenom,
    ROUND(((m.sim_nom + m.sim_prenom) / 2.0)::numeric, 3) AS sim_score,
    to_jsonb(jsonb_strip_nulls(to_jsonb(p1))) AS personne_1,
    to_jsonb(jsonb_strip_nulls(to_jsonb(p2))) AS personne_2,
    CASE
        WHEN m.ts_1 >= m.ts_2 THEN m.id_1
        ELSE m.id_2
    END AS winner_id,
    CASE
        WHEN m.ts_1 < m.ts_2 THEN m.id_1
        ELSE m.id_2
    END AS loser_id
FROM all_matchs m
JOIN main.personne p1 ON p1.id = m.id_1
JOIN main.personne p2 ON p2.id = m.id_2
ORDER BY m.id_1, m.id_2, m.sim_nom DESC, m.sim_prenom DESC;


-- --- api.aidants_connect (V028) ---
CREATE VIEW api.aidants_connect AS (
WITH employeurs AS (
  SELECT DISTINCT ON (pa.personne_id)
    pa.personne_id,
    s.id           AS structure_id,
    s.nom          AS nom,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie) AS adresse,
    a.code_insee   AS code_insee,
    a.nom_commune  AS commune,
    a.departement  AS code_departement
  FROM main.personne_affectations pa
  JOIN main.structure s ON s.id = pa.structure_id
  LEFT JOIN main.adresse a ON a.id = s.adresse_id
  WHERE pa.structure_id IS NOT NULL
    AND pa.est_active = TRUE
  ORDER BY
    pa.personne_id,
    CASE WHEN pa.type IN ('structure_emploi') THEN 0 ELSE 1 END,
    coalesce(pa.updated_at, pa.created_at) DESC,
    pa.id DESC
)
SELECT
  p.aidant_connect_id,
  p.id AS id,
  coalesce(p.nb_accompagnements_ac, 0) AS nb_accompagnements,
  e.code_insee AS code_insee,
  jsonb_strip_nulls(
    jsonb_build_object(
      'id',         e.structure_id,
      'nom',        e.nom,
      'adresse',    e.adresse,
      'code_insee', e.code_insee,
      'commune',    e.commune,
      'departement',e.code_departement
    )
  ) AS structure_employeuse
FROM main.personne p
LEFT JOIN employeurs e ON e.personne_id = p.id
WHERE p.aidant_connect_id IS NOT NULL
);

COMMENT ON VIEW api.aidants_connect IS
  'Aidants Connect : personnes (aidant_connect_id, id, nb_accompagnements) + structure employeuse en JSON (id, nom, adresse, code_insee, commune, departement).';
COMMENT ON COLUMN api.aidants_connect.aidant_connect_id IS
  'Identifiant unique de l''aidant dans le système Aidants Connect.';
COMMENT ON COLUMN api.aidants_connect.id IS
    'Identifiant unique de la personne dans DataSpace.';
COMMENT ON COLUMN api.aidants_connect.nb_accompagnements IS
    'Nombre d''accompagnements / Démarches administratives réalisés par l''aidant via Aidants Connect.';
COMMENT ON COLUMN api.aidants_connect.structure_employeuse IS
    'Informations sur la structure employeuse de l''aidant';
COMMENT ON COLUMN api.aidants_connect.code_insee IS
    'Code INSEE de la commune de la structure employeuse de l''aidant.';

DO $$ BEGIN
  PERFORM 1 FROM pg_roles WHERE rolname = 'postgrest_anct_incub';
  IF FOUND THEN EXECUTE 'GRANT SELECT ON TABLE api.aidants_connect TO postgrest_anct_incub'; END IF;
END $$;


-- --- api.carto (V030) ---
CREATE VIEW api.carto AS (
WITH courriels AS (
   SELECT structure_1.id,
      string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text]), VARIADIC ARRAY[key.key]), '|'::text) AS courriels_concat
      FROM main.structure structure_1,
      LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text])) key(key)
      GROUP BY structure_1.id
   ), personnes AS (
   SELECT sub_table.structure_id,
      jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
      FROM ( SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique'::text, ','::text)
                        ELSE NULL::text[]
                  END, 'email', (personne.contact -> 'courriels'::text) ->> 'mail_pro'::text, 'telephone', personne.contact -> 'telephone'::text) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.est_active = TRUE AND personne_affectations.type::text = 'lieu_activite'::text AND (NOT EXISTS (SELECT 1 FROM main.personne_affectations pa2 WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.est_active = TRUE AND pa2.type = 'structure_emploi') OR personne.aidant_connect_id IS NULL) AND (personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL)
            UNION
            SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique,Aidant Connect'::text, ','::text)
                        ELSE string_to_array('Aidant Connect'::text, ','::text)
                  END) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.est_active = TRUE AND personne_affectations.type::text = 'lieu_activite'::text AND (EXISTS (SELECT 1 FROM main.personne_affectations pa2 WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.type = 'structure_emploi') OR personne.aidant_connect_id IS NOT NULL)) sub_table
      GROUP BY sub_table.structure_id
   )
 SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000'::character varying)::character varying(14) AS pivot,
    structure.nom,
    jsonb_build_object(
      'numero_voie', adresse.numero_voie,
      'repetition', adresse.repetition,
      'nom_voie', adresse.nom_voie,
      'code_postal', adresse.code_postal,
      'commune', adresse.nom_commune,
      'code_insee', adresse.code_insee
    ) AS adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    structure.typologies AS typologie,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source AS source,
    structure.itinerance AS itinerance,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    structure.services AS services,
    structure.publics_specifiquement_adresses AS publics_specifiquement_adresses,
    structure.prise_en_charge_specifique AS prise_en_charge_specifique,
    structure.frais_a_charge AS frais_a_charge,
    structure.dispositif_programmes_nationaux AS dispositif_programmes_nationaux,
    structure.formations_labels AS formations_labels,
    structure.autres_formations_labels AS autres_formations_labels,
    structure.modalites_acces AS modalites_acces,
    structure.modalites_accompagnement AS modalites_accompagnement,
    structure.prise_rdv,
    personnes.mediateurs
   FROM main.structure
   LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
   LEFT JOIN courriels ON courriels.id = structure.id
   LEFT JOIN personnes ON personnes.structure_id = structure.id
  WHERE structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale
);

COMMENT ON VIEW api.carto IS 'Cartographie nationale de l''inclusion numérique.';
COMMENT ON column api.carto.id IS 'Identifiant de la cartographie nationale';
COMMENT ON column api.carto.pivot IS 'Identifiant de la structure (Siret pour les entreprises, RNA pour les associations sans Siret)';
COMMENT ON column api.carto.nom IS 'Nom de la structure';
COMMENT ON column api.carto.adresse IS 'Données relatives à l''adresse de la structure (numero_voie, repetition, nom_voie, code_postal, commune, code_insee)';
COMMENT ON column api.carto.latitude IS 'Latitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.longitude IS 'Longitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.typologie IS 'Typologie de la structure';
COMMENT ON column api.carto.telephone IS 'Numéro de téléphone du lieu.';
COMMENT ON column api.carto.courriels IS 'Courriels du lieu.';
COMMENT ON column api.carto.site_web IS 'Site Internet du lieu.';
COMMENT ON column api.carto.horaires IS 'Horaires au format OSM. cf. https://wiki.openstreetmap.org/wiki/Key:opening_hours/specification#explain:time_domain';
COMMENT ON column api.carto.presentation_resume IS 'Courte description du lieu';
COMMENT ON column api.carto.presentation_detail IS 'Description détaillée du lieu';
COMMENT ON column api.carto.source IS 'Source de la données ou du dernier modificateur.';
COMMENT ON column api.carto.itinerance IS 'Lieu d''inclusion numérique itinérant.';
COMMENT ON column api.carto.date_maj IS 'Date de la dernière mise à jour.';
COMMENT ON column api.carto.services IS 'Les types d''accompagnement proposés dans l''offre du lieu.';
COMMENT ON column api.carto.publics_specifiquement_adresses IS 'Types de public accueilli.';
COMMENT ON column api.carto.prise_en_charge_specifique IS 'Le lieu est en mesure d''accompagner et soutenir des publics ayant des besoins particuliers.';
COMMENT ON column api.carto.prise_en_charge_specifique IS 'Public ayant des besoins particuliers accompagné.';
COMMENT ON column api.carto.frais_a_charge IS 'Conditions financières d''accès.';
COMMENT ON column api.carto.dispositif_programmes_nationaux IS 'Appartenance à un dispositif ou à un programme national.';
COMMENT ON column api.carto.formations_labels IS 'Formations et labels obtenus par le lieu.';
COMMENT ON column api.carto.autres_formations_labels IS 'Autres formations ou labels.';
COMMENT ON column api.carto.modalites_acces IS 'Différentes étapes ou démarches à suivre pour se rendre au lieu d''inclusion numérique et bénéficier de ses services.';
COMMENT ON column api.carto.modalites_accompagnement IS 'Types d''accompagnement proposés';
COMMENT ON column api.carto.prise_rdv IS 'Lien vers le site de prise de rendez-vous.';

DO $$ BEGIN
  PERFORM 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto';
  IF FOUND THEN EXECUTE 'GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto'; END IF;
END $$;


-- --- min.personne_enrichie ---
CREATE VIEW min.personne_enrichie AS
WITH personne_avec_status AS (
  SELECT
    p.*,

    -- Type d'accompagnateur (médiateur ou aidant numérique exclusif)
    CASE
      WHEN p.is_mediateur = true THEN 'mediateur'
      WHEN p.is_mediateur = false OR p.is_mediateur IS NULL THEN 'aidant_numerique'
    END AS type_accompagnateur,

    -- Labellisation aidant connect (un médiateur peut être labellisé AC)
    EXISTS (
      SELECT 1 FROM main.personne_affectations pa
      WHERE pa.personne_id = p.id
        AND pa.source = 'aidants-connect'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
    ) AS labellisation_aidant_connect,

    -- Est actuellement en poste en tant que médiateur
    CASE
      WHEN p.is_mediateur = true
        AND EXISTS (
          SELECT 1 FROM main.personne_affectations pa
          WHERE pa.personne_id = p.id
          AND pa.type = 'structure_emploi'
          AND pa.est_active = TRUE
        )
      THEN true
      ELSE false
    END AS est_actuellement_mediateur_en_poste,

    -- Est actuellement en poste en tant qu'aidant numérique exclusif
    CASE
      WHEN (p.is_mediateur = false OR p.is_mediateur IS NULL)
        AND EXISTS (
          SELECT 1 FROM main.personne_affectations pa
          WHERE pa.personne_id = p.id
            AND pa.source = 'aidants-connect'
            AND pa.est_active = TRUE
            AND pa.type = 'structure_emploi'
        )
      THEN true
      ELSE false
    END AS est_actuellement_aidant_numerique_en_poste

  FROM main.personne p
)
SELECT
  *,
  -- Est actuellement conseiller numérique (médiateur avec contrat CN actif)
  CASE
    WHEN type_accompagnateur = 'mediateur'
      AND EXISTS (
        SELECT 1 FROM main.contrat c
        WHERE c.personne_id = personne_avec_status.id
        AND c.date_rupture IS NULL
      )
    THEN true
    ELSE false
  END AS est_actuellement_conseiller_numerique,

  -- Est actuellement coordinateur actif (utilise les colonnes déjà calculées)
  CASE
    WHEN is_coordinateur = true
      AND (est_actuellement_mediateur_en_poste = true OR est_actuellement_aidant_numerique_en_poste = true)
    THEN true
    ELSE false
  END AS est_actuellement_coordo_actif,

  -- ID de la structure employeuse (depuis personne_affectations)
  (
    SELECT pa.structure_id
    FROM main.personne_affectations pa
    WHERE pa.personne_id = personne_avec_status.id
    AND pa.type = 'structure_emploi'
    AND pa.est_active = TRUE
    ORDER BY pa.structure_id ASC
    LIMIT 1
  ) AS structure_employeuse_id

FROM personne_avec_status;


NOTIFY pgrst, 'reload schema';

-- Pour tester : remplacer COMMIT par ROLLBACK
COMMIT;
