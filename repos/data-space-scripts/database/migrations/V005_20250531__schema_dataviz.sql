DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'app_metabase') THEN

      RAISE NOTICE 'Role "app_metabase" already exists. Skipping.';
   ELSE
      CREATE ROLE app_metabase LOGIN;
   END IF;
END
$do$;

GRANT CONNECT ON DATABASE dataspace_test, dataspace_dev, dataspace_prod TO app_metabase;

CREATE SCHEMA IF NOT EXISTS dataviz;

GRANT USAGE ON SCHEMA dataviz TO app_metabase;

-- Set defaults privileges
ALTER DEFAULT PRIVILEGES IN SCHEMA dataviz GRANT SELECT ON TABLES TO app_metabase;


CREATE VIEW dataviz.region AS (
    SELECT
        region.code,
        region.nom
    FROM admin.region
);

COMMENT ON VIEW dataviz.region IS 'Liste des régions du référentiel administratif (IGN).';


CREATE VIEW dataviz.departement AS (
    SELECT
        region.code AS region_code,
        region.nom AS region_nom,
        departement.code,
        departement.nom
    FROM admin.departement
    INNER JOIN admin.region ON region.id = admin.departement.region_id
);

COMMENT ON VIEW dataviz.departement IS 'Liste des départements du référentiel administratif (IGN).';


CREATE VIEW dataviz.commune AS (
    SELECT
        region.code AS region_code,
        region.nom AS region_nom,
        departement.code AS departement_code,
        departement.nom AS departement_nom,
        commune.code_insee,
        commune.statut,
        commune.nom,
        commune.population
    FROM admin.commune
    INNER JOIN admin.departement ON departement.id = admin.commune.departement_id
    INNER JOIN admin.region ON region.id = admin.departement.region_id
);

COMMENT ON VIEW dataviz.commune IS 'Liste des communes du référentiel administratif (IGN).';
COMMENT ON COLUMN dataviz.commune.statut IS 'Les communes peuvent avoir le statut : Commune simple, Sous-préfecture, Préfecture, Préfecture de région, Capitale d''état.';
COMMENT ON COLUMN dataviz.commune.population IS 'La population municipale comprend les personnes résidant habituellement sur le territoire de la communale (INSEE via IGN).';


CREATE VIEW dataviz.epci AS (
    SELECT
        epci.code,
        epci.type,
        epci.nom
    FROM admin.epci
);

COMMENT ON VIEW dataviz.epci IS 'Liste des EPCI du référentiel administratif (IGN).';
COMMENT ON COLUMN dataviz.epci.code IS 'Code SIREN de l''EPCI';
COMMENT ON COLUMN dataviz.epci.type IS 'Les EPCI peuvent être de type : Communauté de communes, Communauté d''agglomération, Communauté urbaine, Métropole, Établissement public territorial.';


CREATE VIEW dataviz.commune_epci AS (
    SELECT
        epci.code AS epci_code,
        epci.type AS epci_type,
        epci.nom AS epci_nom,
        commune.code_insee,
        commune.statut,
        commune.nom,
        commune.population
    FROM admin.commune_epci
    INNER JOIN admin.commune ON commune_epci.commune_id = commune.id
    INNER JOIN admin.epci ON commune_epci.epci_id = epci.id
);

COMMENT ON VIEW dataviz.commune_epci IS 'Liste des appartenances des communes aux EPCI (IGN). Nota: certaines communes peuvent appartenir à plusieurs EPCI.';
COMMENT ON COLUMN dataviz.commune_epci.epci_type IS 'Les EPCI peuvent être de type : Communauté de communes, Communauté d''agglomération, Communauté urbaine, Métropole, Établissement public territorial.';


CREATE VIEW dataviz.adresse AS (
    SELECT
        adresse.id,
        adresse.clef_interop,
        adresse.code_ban,
        adresse.numero_voie,
        adresse.repetition,
        adresse.nom_voie,
        adresse.code_postal,
        adresse.nom_commune,
        adresse.code_insee,
        coll_terr.departement_code,
        coll_terr.departement_nom,
        coll_terr.region_code,
        coll_terr.region_nom,
        st_y(adresse.geom) AS latitude,
        st_x(adresse.geom) AS longitude
    FROM main.adresse
    LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
);

COMMENT ON VIEW dataviz.adresse IS '';
COMMENT ON COLUMN dataviz.adresse.clef_interop IS 'Clef d''interopérabilité de la Base Adresse Nationale en attendant de basculer complètement sur le code BAN.';
COMMENT ON COLUMN dataviz.adresse.code_ban IS 'Identifiant unique et perenne de l''adresse. En cours de déploiement à la BAN.';
COMMENT ON COLUMN dataviz.adresse.latitude IS 'Latitude de l''adresse (y) en WGS84, EPSG:4326.';
COMMENT ON COLUMN dataviz.adresse.longitude IS 'Longitude de l''adresse (x) en WGS84, EPSG:4326.';


CREATE VIEW dataviz.zone_quartier_prio AS (
    SELECT
        zonage.code,
        zonage.libelle,
        zonage.code_insee,
        commune.nom AS nom_commune,
        commune.statut AS statut_commune,
        departement.code AS code_departement,
        departement.nom AS nom_departement
    FROM admin.zonage
    INNER JOIN admin.commune ON zonage.code_insee = commune.code_insee
    INNER JOIN admin.departement ON commune.departement_id = departement.id
    WHERE zonage.type = 'QPV'
);

COMMENT ON VIEW dataviz.zone_quartier_prio IS 'Zones des Quartiers prioritaires de la politique de la ville. Source : https://www.data.gouv.fr/fr/datasets/quartiers-prioritaires-de-la-politique-de-la-ville-qpv/';


CREATE VIEW dataviz.zone_france_ruralite_revital AS (
    SELECT
        commune.nom AS nom_commune,
        commune.statut AS statut_commune,
        departement.code AS code_departement,
        departement.nom AS nom_departement,
        commune.population,
        zonage.code_insee,
        zonage.commentaire AS complement
    FROM admin.zonage
    INNER JOIN admin.commune ON zonage.code_insee = commune.code_insee
    INNER JOIN admin.departement ON commune.departement_id = departement.id
    WHERE zonage.type = 'FRR'
);

COMMENT ON VIEW dataviz.zone_france_ruralite_revital IS 'Zones France ruralités revitalisation. Source: https://www.collectivites-locales.gouv.fr/cohesion-territoriale/france-ruralites-revitalisation';


CREATE VIEW dataviz.indice_fragilite_numerique_commune AS (
    SELECT
        ifn.code_insee AS code_commune,
        ifn.score,
        commune.nom AS nom_commune,
        commune.population,
        departement.code AS code_departement,
        departement.nom AS nom_departement
    FROM admin.ifn_commune AS ifn
    LEFT JOIN admin.commune ON ifn.code_insee = commune.code_insee
    LEFT JOIN admin.departement ON commune.departement_id = departement.id
);

COMMENT ON VIEW dataviz.indice_fragilite_numerique_commune IS 'Commune IFN - Indice de Fragilité Numérique. Source: https://fragilite-numerique.fr/';


CREATE VIEW dataviz.indice_fragilite_numerique_departement AS (
    SELECT
        departement.code AS code_departement,
        ifn.score,
        departement.nom AS nom_departement,
        SUM(commune.population) AS population
    FROM admin.ifn_departement AS ifn
    LEFT JOIN admin.departement ON departement.code = ifn.code
    LEFT JOIN admin.commune ON commune.departement_id = departement.id
    GROUP BY departement.code, ifn.score, departement.nom
);

COMMENT ON VIEW dataviz.indice_fragilite_numerique_departement IS 'Département IFN - Indice de Fragilité Numérique. Source: https://fragilite-numerique.fr/';


CREATE VIEW dataviz.categorie_juridique AS (
    SELECT
        categories_juridiques.code,
        categories_juridiques.nom,
        categories_juridiques.niveau
    FROM reference.categories_juridiques
);


CREATE OR REPLACE VIEW dataviz.structures AS (
    SELECT
        structure.*,
        adresse.id AS addr_id,
        adresse.clef_interop AS addr_clef_interop,
        adresse.code_ban AS addr_code_ban,
        adresse.departement AS addr_departement,
        adresse.code_postal AS addr_code_postal,
        adresse.code_insee AS addr_code_insee,
        adresse.nom_commune AS addr_nom_commune,
        adresse.nom_voie AS addr_nom_voie,
        adresse.repetition AS addr_repetition,
        adresse.numero_voie AS addr_numero_voie,
        coll_terr.region_id AS coll_terr_region_id,
        coll_terr.region_code AS coll_terr_region_code,
        coll_terr.region_nom AS coll_terr_region_nom,
        coll_terr.departement_id AS coll_terr_departement_id,
        coll_terr.departement_code AS coll_terr_departement_code,
        coll_terr.departement_nom AS coll_terr_departement_nom,
        coll_terr.commune_id AS coll_terr_commune_id,
        coll_terr.code_insee AS coll_terr_code_insee,
        coll_terr.commune_nom AS coll_terr_commune_nom,
        categories_juridiques.nom AS categories_juridiques_nom,
        zonage.type AS zonage_type,
        zonage.id AS zonage_id,
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

CREATE VIEW dataviz.lieux_inclusion_numerique AS (
WITH
-- coordinateurs AS (
--     SELECT structure_id, COUNT(*) AS nbr
--     FROM main.personne
--     INNER JOIN main.personne_structures_emplois AS e ON e.personne_id = personne.id
--     WHERE is_coordinateur IS True AND en_cours IS True
--     GROUP BY structure_id
-- ),
conseillers AS (
    SELECT
        personne.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_structures_emplois AS e ON personne.id = e.personne_id
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND en_cours IS TRUE
    GROUP BY personne.structure_id
),

lieux AS (
    SELECT structure_id
    FROM main.personne_lieux_activites
    WHERE en_cours IS TRUE
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
    INNER JOIN main.personne_structures_emplois AS e ON personne.id = e.personne_id
    WHERE is_coordinateur IS TRUE AND en_cours IS TRUE
    GROUP BY personne.structure_id
),

conseillers AS (
    SELECT
        personne.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_structures_emplois AS e ON personne.id = e.personne_id
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND en_cours IS TRUE
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


CREATE OR REPLACE VIEW dataviz.poste AS (
    SELECT
    poste.poste_conum_id AS id_poste,
    structure.structure_tp_id AS id_structure,
    personne.cn_pg_id AS id_cn,
    poste.etat,
    poste.date_attribution,
    poste.date_rendu_poste AS date_rendu_de_poste,
    poste.typologie,
    poste.action_coselec,
    poste.origine_transfert AS origine_transfert,
    structure.nom AS nom_structure,
    structure.siret,
    CASE WHEN structure.publique IS True THEN 'Publique' ELSE 'Privée' END AS "publique/privée",
    categories_juridiques.nom AS typologie_juridique,
    NULL::text AS "etat_de_l'instruction",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "nom_du_département",
    coll_terr.departement_code AS "code_département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    coll_terr.code_insee,
    NULL::text AS source_de_financement,
    NULL::text AS "date_début/signature_convention",
    NULL::text AS date_fin_convention,
    NULL::text AS "date_début_financement",
    NULL::text AS date_de_fin_financement,
    NULL::text AS "mois_consommés_sur_la_période_de_financement",
    NULL::text AS "mois_consommés_sur_le_poste",
    NULL::text AS montant_subventions_hors_bonification,
    NULL::text AS territoire_prioritaire,
    NULL::text AS "bonifications_découlant_du_lieu_de_permanence",
    NULL::text AS montant_subventions_total,
    NULL::text AS "cp_à_date",
    NULL::text AS "cp_consommé",
    NULL::text AS "reste_à_payer_convention",
    NULL::text AS avoir,
    NULL::text AS montant_versement_1e_tranche,
    NULL::text AS montant_versement_2e_tranche,
    NULL::text AS montant_versement_3e_tranche,
    NULL::text AS date_versement_1e_tranche,
    NULL::text AS date_versement_2e_tranche,
    NULL::text AS date_versement_3e_tranche,
    personne.nom,
    personne.prenom AS "prénom",
    concat_ws(', ', personne.contact -> 'courriels' ->> 'mail_pro', personne.contact -> 'courriels' ->> 'mail_perso')::text AS emails,
    contrat.type AS type_ct,
    contrat.date_debut AS date_debut_contrat,
    contrat.date_fin AS date_fin_contrat,
    contrat.date_rupture AS date_rupture,
    CASE WHEN contrat.date_rupture IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "rupture_anticipée",
    formation.lot AS lot,
    formation.marche_formation AS "marché_de_formation",
    formation.label AS formation,
    formation.date_debut AS "date_de_départ",
    formation.date_fin AS date_de_fin,
    formation.lieu,
    formation.parcours,
    formation.observations AS statut_formation_conum,
    NULL::text AS cra,
    CASE WHEN poste.poste_renouvele IS TRUE THEN 'Oui' WHEN poste.poste_renouvele IS FALSE THEN 'Non' ELSE Null END AS "poste_renouvelé",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure,
    structure.contact ->> 'nom' AS "nom_référent_tp",
    structure.contact ->> 'prenom' AS "prénom_référent_tp",
    structure.contact ->> 'telephone' AS telephone,
    structure.contact -> 'courriels' ->> 'mail_gestionnaire' AS mail_gestionnaire,
    structure.contact -> 'courriels' ->> 'mail_2' AS mail_2,
    structure.contact -> 'courriels' ->> 'referent_hierarchique' AS "référent_hiérarchique",
    CASE WHEN formation.pix IS TRUE THEN 'Oui' WHEN formation.pix IS FALSE THEN 'Non' ELSE Null END AS pix,
    CASE WHEN formation.remn IS TRUE THEN 'Oui' WHEN formation.remn IS FALSE THEN 'Non' ELSE Null END AS remn
    FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON coll_terr.code_insee::text = adresse.code_insee::text
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique::text = categories_juridiques.code::text
    INNER JOIN main.poste ON structure.id = poste.structure_id
    LEFT JOIN main.personne ON poste.personne_id = personne.id
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN main.contrat ON contrat.personne_id = personne.id
);

-- Vue Poste pseudonymisée
-- Même vue que ci-dessus, mais sans les colonnes personne.nom, personne.prenom, personne.contact, structure.contact
CREATE OR REPLACE VIEW dataviz.poste_pseudonymisee AS (
    SELECT
    poste.poste_conum_id AS id_poste,
    structure.structure_tp_id AS id_structure,
    personne.cn_pg_id AS id_cn,
    poste.etat,
    poste.date_attribution,
    poste.date_rendu_poste AS date_rendu_de_poste,
    poste.typologie,
    poste.action_coselec,
    poste.origine_transfert AS origine_transfert,
    structure.nom AS nom_structure,
    structure.siret,
    CASE WHEN structure.publique IS True THEN 'Publique' ELSE 'Privée' END AS "publique/privée",
    categories_juridiques.nom AS typologie_juridique,
    NULL::text AS "etat_de_l'instruction",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "nom_du_département",
    coll_terr.departement_code AS "code_département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    coll_terr.code_insee,
    NULL::text AS source_de_financement,
    NULL::text AS "date_début/signature_convention",
    NULL::text AS date_fin_convention,
    NULL::text AS "date_début_financement",
    NULL::text AS date_de_fin_financement,
    NULL::text AS "mois_consommés_sur_la_période_de_financement",
    NULL::text AS "mois_consommés_sur_le_poste",
    NULL::text AS montant_subventions_hors_bonification,
    NULL::text AS territoire_prioritaire,
    NULL::text AS "bonifications_découlant_du_lieu_de_permanence",
    NULL::text AS montant_subventions_total,
    NULL::text AS "cp_à_date",
    NULL::text AS "cp_consommé",
    NULL::text AS "reste_à_payer_convention",
    NULL::text AS avoir,
    NULL::text AS montant_versement_1e_tranche,
    NULL::text AS montant_versement_2e_tranche,
    NULL::text AS montant_versement_3e_tranche,
    NULL::text AS date_versement_1e_tranche,
    NULL::text AS date_versement_2e_tranche,
    NULL::text AS date_versement_3e_tranche,
    contrat.type AS type_ct,
    contrat.date_debut AS date_debut_contrat,
    contrat.date_fin AS date_fin_contrat,
    contrat.date_rupture AS date_rupture,
    CASE WHEN contrat.date_rupture IS NOT NULL THEN 'Oui' ELSE 'Non' END AS "rupture_anticipée",
    formation.lot AS lot,
    formation.marche_formation AS "marché_de_formation",
    formation.label AS formation,
    formation.date_debut AS "date_de_départ",
    formation.date_fin AS date_de_fin,
    formation.lieu,
    formation.parcours,
    formation.observations AS statut_formation_conum,
    NULL::text AS cra,
    CASE WHEN poste.poste_renouvele IS TRUE THEN 'Oui' WHEN poste.poste_renouvele IS FALSE THEN 'Non' ELSE Null END AS "poste_renouvelé",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure,
    CASE WHEN formation.pix IS TRUE THEN 'Oui' WHEN formation.pix IS FALSE THEN 'Non' ELSE Null END AS pix,
    CASE WHEN formation.remn IS TRUE THEN 'Oui' WHEN formation.remn IS FALSE THEN 'Non' ELSE Null END AS remn
    FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON coll_terr.code_insee::text = adresse.code_insee::text
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique::text = categories_juridiques.code::text
    INNER JOIN main.poste ON structure.id = poste.structure_id
    LEFT JOIN main.personne ON poste.personne_id = personne.id
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN main.contrat ON contrat.personne_id = personne.id
);


CREATE VIEW dataviz.personne AS (
    WITH lieux AS (
        SELECT
personne_id,
            count(*) AS nbr
        FROM main.personne_lieux_activites
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
    LEFT JOIN main.personne_structures_emplois ON personne.id = personne_structures_emplois.personne_id
    LEFT JOIN main.structure ON personne_structures_emplois.structure_id = structure.id
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
        FROM main.personne_lieux_activites
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
    LEFT JOIN main.personne_structures_emplois ON personne.id = personne_structures_emplois.personne_id
    LEFT JOIN main.structure ON personne_structures_emplois.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id
    );
