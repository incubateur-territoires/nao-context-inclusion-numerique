DROP VIEW dataviz.poste;

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
    poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
    poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "nom_du_département",
    coll_terr.departement_code AS "code_département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    coll_terr.code_insee,
    subvention.source_financement AS source_de_financement,
    subvention.date_debut_convention AS "date_début/signature_convention",
    subvention.date_fin_convention AS date_fin_convention,
    subvention.date_debut_financement AS "date_début_financement",
    subvention.date_fin_financement AS date_de_fin_financement,
    subvention.mois_utilises_periode_financement AS "mois_consommés_sur_la_période_de_financement",
    subvention.mois_utilises_poste AS "mois_consommés_sur_le_poste",
    subvention.montant_subvention AS montant_subventions_hors_bonification,
    CASE WHEN subvention.is_territoire_prioritaire IS NOT NULL THEN 'Oui' ELSE 'Non' END AS territoire_prioritaire,
    subvention.montant_bonification AS "bonifications_découlant_du_lieu_de_permanence",
    subvention.montant_subvention + subvention.montant_bonification AS montant_subventions_total,
    subvention.cp_a_date AS "cp_à_date",
    NULL::text AS "cp_consommé",
    NULL::text AS "reste_à_payer_convention",
    subvention.avoir AS avoir,
    subvention.versement_1 AS montant_versement_1e_tranche,
    subvention.versement_2 AS montant_versement_2e_tranche,
    subvention.versement_3 AS montant_versement_3e_tranche,
    subvention.date_versement_1 AS date_versement_1e_tranche,
    subvention.date_versement_2 AS date_versement_2e_tranche,
    subvention.date_versement_3 AS date_versement_3e_tranche,
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
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
);

-- Vue Poste pseudonymisée
DROP VIEW dataviz.poste_pseudonymisee;
-- Même vue que ci-dessus, mais sans les colonnes personne.nom, personne.prenom, personne.contact, structure.contact
CREATE VIEW dataviz.poste_pseudonymisee AS (
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
    subvention.source_financement AS source_de_financement,
    subvention.date_debut_convention AS "date_début/signature_convention",
    subvention.date_fin_convention AS date_fin_convention,
    subvention.date_debut_financement AS "date_début_financement",
    subvention.date_fin_financement AS date_de_fin_financement,
    subvention.mois_utilises_periode_financement AS "mois_consommés_sur_la_période_de_financement",
    subvention.mois_utilises_poste AS "mois_consommés_sur_le_poste",
    subvention.montant_subvention AS montant_subventions_hors_bonification,
    CASE WHEN subvention.is_territoire_prioritaire IS NOT NULL THEN 'Oui' ELSE 'Non' END AS territoire_prioritaire,
    subvention.montant_bonification AS "bonifications_découlant_du_lieu_de_permanence",
    subvention.montant_subvention + subvention.montant_bonification AS montant_subventions_total,
    subvention.cp_a_date AS "cp_à_date",
    NULL::text AS "cp_consommé",
    NULL::text AS "reste_à_payer_convention",
    subvention.avoir AS avoir,
    subvention.versement_1 AS montant_versement_1e_tranche,
    subvention.versement_2 AS montant_versement_2e_tranche,
    subvention.versement_3 AS montant_versement_3e_tranche,
    subvention.date_versement_1 AS date_versement_1e_tranche,
    subvention.date_versement_2 AS date_versement_2e_tranche,
    subvention.date_versement_3 AS date_versement_3e_tranche,
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
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
);
