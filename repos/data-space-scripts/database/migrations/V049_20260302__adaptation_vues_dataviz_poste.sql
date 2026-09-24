-- Migration V049: Adaptation des vues dataviz.poste et dataviz.poste_pseudonymisee
-- Suite à la refonte de la table subvention (V048)
--
-- V048 a supprimé les anciennes vues avec CASCADE lors de la suppression de source_financement
-- Cette migration les recrée avec la nouvelle structure dénormalisée
--
-- Stratégie : UNION pour créer 3 lignes virtuelles (DGCL, DITP, DGE) par poste
-- afin de maintenir la compatibilité avec Metabase et autres outils

DROP VIEW IF EXISTS dataviz.poste;

CREATE VIEW dataviz.poste AS (
    -- Ligne DGCL (V1)
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
        poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
        poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
        coll_terr.region_nom AS "région",
        coll_terr.departement_nom AS "nom_du_département",
        coll_terr.departement_code AS "code_département",
        adresse.code_postal,
        coll_terr.commune_nom AS commune,
        coll_terr.code_insee,
        'DGCL' AS source_de_financement,
        subvention.date_debut_convention_dgcl AS "date_début/signature_convention",
        subvention.date_fin_convention_dgcl AS date_fin_convention,
        subvention.date_debut_financement_dgcl AS "date_début_financement",
        subvention.date_fin_financement_dgcl AS date_de_fin_financement,
        subvention.mois_utilises_periode_financement_dgcl AS "mois_consommés_sur_la_période_de_financement",
        NULL::smallint AS "mois_consommés_sur_le_poste",
        subvention.montant_subvention_v1 AS "montant_subventions_hors_bonification",
        'Non' AS territoire_prioritaire,
        NULL::bigint AS "bonification découlant du lieu de permanence",
        subvention.montant_subvention_v1 AS "montant_subventions_total",
        NULL::bigint AS "cp_à_date",
        CASE
            WHEN (subvention.montant_subvention_v1) > 0
            THEN (subvention.montant_versement_v1)::numeric / (subvention.montant_subvention_v1)::numeric
            ELSE NULL
        END AS "cp_consommé",
        (subvention.montant_subvention_v1) - (subvention.montant_versement_v1) AS "reste_à_payer_convention",
        subvention.montant_avoir_v1 AS avoir,
        subvention.montant_versement_v1 AS montant_versement_1e_tranche,
        NULL::bigint AS montant_versement_2e_tranche,
        NULL::bigint AS montant_versement_3e_tranche,
        NULL::date AS date_versement_1e_tranche,
        NULL::date AS date_versement_2e_tranche,
        NULL::date AS date_versement_3e_tranche,
        personne.nom,
        personne.prenom AS "prénom",
        concat_ws(', ',
            personne.contact -> 'coop' ->> 'email',
            personne.contact -> 'idposte' ->> 'mail_pro',
            personne.contact -> 'idposte' ->> 'mail_perso'
        ) AS emails,
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
        contact_ref.nom::text AS "nom_référent_tp",
        contact_ref.prenom::text AS "prénom_référent_tp",
        contact_ref.telephone::text AS telephone,
        contact_ref.email::text AS mail_gestionnaire,
        NULL::text AS mail_2,
        NULL::text AS "référent_hiérarchique",
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
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
    LEFT JOIN LATERAL (
        SELECT c.nom, c.prenom, c.telephone, c.email
        FROM main.contact_structure cs
        JOIN main.contact c ON c.id = cs.contact_id
        WHERE cs.structure_id = structure.id
        ORDER BY c.id
        LIMIT 1
    ) contact_ref ON true
    WHERE subvention.montant_subvention_v1 IS NOT NULL  -- Seulement si DGCL existe

    UNION ALL

    -- Ligne DITP (V2)
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
        poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
        poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
        coll_terr.region_nom AS "région",
        coll_terr.departement_nom AS "nom_du_département",
        coll_terr.departement_code AS "code_département",
        adresse.code_postal,
        coll_terr.commune_nom AS commune,
        coll_terr.code_insee,
        'DITP' AS source_de_financement,
        subvention.date_debut_convention_ditp AS "date_début/signature_convention",
        subvention.date_fin_convention_ditp AS date_fin_convention,
        subvention.date_debut_financement_ditp AS "date_début_financement",
        subvention.date_fin_financement_ditp AS date_de_fin_financement,
        subvention.mois_utilises_periode_financement_ditp AS "mois_consommés_sur_la_période_de_financement",
        NULL::smallint AS "mois_consommés_sur_le_poste",
        subvention.montant_subvention_v2 - COALESCE(subvention.montant_bonification_v2, 0) AS "montant_subventions_hors_bonification",
        CASE WHEN subvention.montant_bonification_v2 > 0 THEN 'Oui' ELSE 'Non' END AS territoire_prioritaire,
        subvention.montant_bonification_v2 AS "bonification découlant du lieu de permanence",
        subvention.montant_subvention_v2 AS "montant_subventions_total",
        NULL::bigint AS "cp_à_date",
        CASE
            WHEN subvention.montant_subvention_v2 > 0
            THEN (subvention.versement_1_v2 + COALESCE(subvention.versement_2_v2, 0) + COALESCE(subvention.versement_3_v2, 0))::numeric / subvention.montant_subvention_v2::numeric
            ELSE NULL
        END AS "cp_consommé",
        subvention.montant_subvention_v2 - (COALESCE(subvention.versement_1_v2, 0) + COALESCE(subvention.versement_2_v2, 0) + COALESCE(subvention.versement_3_v2, 0)) AS "reste_à_payer_convention",
        subvention.montant_avoir_v2 AS avoir,
        subvention.versement_1_v2 AS montant_versement_1e_tranche,
        subvention.versement_2_v2 AS montant_versement_2e_tranche,
        subvention.versement_3_v2 AS montant_versement_3e_tranche,
        subvention.date_versement_1_v2 AS date_versement_1e_tranche,
        subvention.date_versement_2_v2 AS date_versement_2e_tranche,
        subvention.date_versement_3_v2 AS date_versement_3e_tranche,
        personne.nom,
        personne.prenom AS "prénom",
        concat_ws(', ',
            personne.contact -> 'coop' ->> 'email',
            personne.contact -> 'idposte' ->> 'mail_pro',
            personne.contact -> 'idposte' ->> 'mail_perso'
        ) AS emails,
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
        contact_ref.nom::text AS "nom_référent_tp",
        contact_ref.prenom::text AS "prénom_référent_tp",
        contact_ref.telephone::text AS telephone,
        contact_ref.email::text AS mail_gestionnaire,
        NULL::text AS mail_2,
        NULL::text AS "référent_hiérarchique",
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
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
    LEFT JOIN LATERAL (
        SELECT c.nom, c.prenom, c.telephone, c.email
        FROM main.contact_structure cs
        JOIN main.contact c ON c.id = cs.contact_id
        WHERE cs.structure_id = structure.id
        ORDER BY c.id
        LIMIT 1
    ) contact_ref ON true
    WHERE subvention.date_debut_financement_ditp IS NOT NULL  -- Seulement si DITP existe

    UNION ALL

    -- Ligne DGE (V2)
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
        poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
        poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
        coll_terr.region_nom AS "région",
        coll_terr.departement_nom AS "nom_du_département",
        coll_terr.departement_code AS "code_département",
        adresse.code_postal,
        coll_terr.commune_nom AS commune,
        coll_terr.code_insee,
        'DGE' AS source_de_financement,
        subvention.date_debut_convention_dge AS "date_début/signature_convention",
        subvention.date_fin_convention_dge AS date_fin_convention,
        subvention.date_debut_financement_dge AS "date_début_financement",
        subvention.date_fin_financement_dge AS date_de_fin_financement,
        subvention.mois_utilises_periode_financement_dge AS "mois_consommés_sur_la_période_de_financement",
        NULL::smallint AS "mois_consommés_sur_le_poste",
        subvention.montant_subvention_v2 - COALESCE(subvention.montant_bonification_v2, 0) AS "montant_subventions_hors_bonification",
        CASE WHEN subvention.montant_bonification_v2 > 0 THEN 'Oui' ELSE 'Non' END AS territoire_prioritaire,
        subvention.montant_bonification_v2 AS "bonification découlant du lieu de permanence",
        subvention.montant_subvention_v2 AS "montant_subventions_total",
        NULL::bigint AS "cp_à_date",
        CASE
            WHEN subvention.montant_subvention_v2 > 0
            THEN (COALESCE(subvention.versement_1_v2, 0) + COALESCE(subvention.versement_2_v2, 0) + COALESCE(subvention.versement_3_v2, 0))::numeric / subvention.montant_subvention_v2::numeric
            ELSE NULL
        END AS "cp_consommé",
        subvention.montant_subvention_v2 - (COALESCE(subvention.versement_1_v2, 0) + COALESCE(subvention.versement_2_v2, 0) + COALESCE(subvention.versement_3_v2, 0)) AS "reste_à_payer_convention",
        subvention.montant_avoir_v2 AS avoir,
        subvention.versement_1_v2 AS montant_versement_1e_tranche,
        subvention.versement_2_v2 AS montant_versement_2e_tranche,
        subvention.versement_3_v2 AS montant_versement_3e_tranche,
        subvention.date_versement_1_v2 AS date_versement_1e_tranche,
        subvention.date_versement_2_v2 AS date_versement_2e_tranche,
        subvention.date_versement_3_v2 AS date_versement_3e_tranche,
        personne.nom,
        personne.prenom AS "prénom",
        concat_ws(', ',
            personne.contact -> 'coop' ->> 'email',
            personne.contact -> 'idposte' ->> 'mail_pro',
            personne.contact -> 'idposte' ->> 'mail_perso'
        ) AS emails,
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
        contact_ref.nom::text AS "nom_référent_tp",
        contact_ref.prenom::text AS "prénom_référent_tp",
        contact_ref.telephone::text AS telephone,
        contact_ref.email::text AS mail_gestionnaire,
        NULL::text AS mail_2,
        NULL::text AS "référent_hiérarchique",
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
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
    LEFT JOIN LATERAL (
        SELECT c.nom, c.prenom, c.telephone, c.email
        FROM main.contact_structure cs
        JOIN main.contact c ON c.id = cs.contact_id
        WHERE cs.structure_id = structure.id
        ORDER BY c.id
        LIMIT 1
    ) contact_ref ON true
    WHERE subvention.date_debut_financement_dge IS NOT NULL  -- Seulement si DGE existe
);

COMMENT ON VIEW dataviz.poste IS 'Vue dénormalisée des postes avec subventions. Crée une ligne par source de financement (DGCL, DITP, DGE) pour compatibilité avec outils existants.';

-- Vue Poste pseudonymisée (sans les données personnelles)
DROP VIEW IF EXISTS dataviz.poste_pseudonymisee;

CREATE VIEW dataviz.poste_pseudonymisee AS (
    SELECT
        id_poste,
        id_structure,
        id_cn,
        etat,
        date_attribution,
        date_rendu_de_poste,
        typologie,
        action_coselec,
        origine_transfert,
        nom_structure,
        siret,
        "publique/privée",
        typologie_juridique,
        "etat_de_l'instruction v1",
        "etat_de_l'instruction v2",
        "région",
        "nom_du_département",
        "code_département",
        code_postal,
        commune,
        code_insee,
        source_de_financement,
        "date_début/signature_convention",
        date_fin_convention,
        "date_début_financement",
        date_de_fin_financement,
        "mois_consommés_sur_la_période_de_financement",
        "mois_consommés_sur_le_poste",
        "montant_subventions_hors_bonification",
        territoire_prioritaire,
        "bonification découlant du lieu de permanence",
        "montant_subventions_total",
        "cp_à_date",
        "cp_consommé",
        "reste_à_payer_convention",
        avoir,
        montant_versement_1e_tranche,
        montant_versement_2e_tranche,
        montant_versement_3e_tranche,
        date_versement_1e_tranche,
        date_versement_2e_tranche,
        date_versement_3e_tranche,
        type_ct,
        date_debut_contrat,
        date_fin_contrat,
        date_rupture,
        "rupture_anticipée",
        lot,
        "marché_de_formation",
        formation,
        "date_de_départ",
        date_de_fin,
        lieu,
        parcours,
        statut_formation_conum,
        cra,
        "poste_renouvelé",
        adresse_structure,
        pix,
        remn
    FROM dataviz.poste
);

COMMENT ON VIEW dataviz.poste_pseudonymisee IS 'Vue pseudonymisée (sans données personnelles) des postes avec subventions.';
