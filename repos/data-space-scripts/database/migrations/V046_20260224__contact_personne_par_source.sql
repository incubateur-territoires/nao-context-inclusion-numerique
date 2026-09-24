-- Migration : restructuration du champ contact de main.personne
-- Ancienne structure : {"courriels": {"mail_pro": "...", "mail_perso": "..."}, "telephone": "..."}
-- Nouvelle structure : {"coop": {"email": "...", "telephone": "..."}, "idposte": {"mail_pro": "...", "mail_perso": "..."}}

-- ============================================================
-- 1. Fonction api.get_mediateur : recherche par email
-- ============================================================
CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email (toutes sources)
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'coop' ->> 'email' = email
       OR p.contact -> 'idposte' ->> 'mail_pro' = email
       OR p.contact -> 'idposte' ->> 'mail_perso' = email
    LIMIT 1;

    RETURN QUERY
    WITH cn_coordonnes AS (
        SELECT coordinateur_id,
        jsonb_agg(
            jsonb_build_object(
                'ids', jsonb_build_object(
                    'dataspace', personne.id,
                    'aidant_connect', personne.aidant_connect_id,
                    'conseiller_numerique', personne.conseiller_numerique_id,
                    'pg_id', personne.cn_pg_id,
                    'coop', personne.coop_id),
                'nom', personne.nom,
                'prenom', personne.prenom,
                'contact', personne.contact
            )
        ) AS conseillers_numerique_coordonnes
        FROM main.coordination_mediation
        INNER JOIN main.personne ON personne.id = mediateur_id
        WHERE coordination_mediation.suppression IS NULL
        AND coordinateur_id = var_personne_id
        GROUP BY coordinateur_id
    ),
    structures_employeuses AS (
        SELECT personne_affectations.personne_id,
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', structure.id,
                        'aidant_connect', structure.structure_ac_id,
                        'coop', structure.structure_coop_id,
                        'pg_id', structure.structure_tp_id),
                    'siret', structure.siret,
                    'nom', structure.nom,
                    'contact', structure.contact,
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                    ),
                    'contrats', (SELECT
                    jsonb_agg(
                        jsonb_build_object(
                            'date_debut', contrat.date_debut,
                            'date_fin', contrat.date_fin,
                            'date_rupture', contrat.date_rupture,
                            'type', contrat.type
                        )
                    )
                    FROM main.contrat
                    WHERE (contrat.structure_id = structure.id OR contrat.structure_id IS NULL) AND contrat.personne_id = personne_affectations.personne_id)
                )
            ) AS structures
        FROM main.personne_affectations
        INNER JOIN main.structure ON structure.id = personne_affectations.structure_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        WHERE personne_affectations.personne_id = var_personne_id
        AND personne_affectations.type = 'structure_emploi'
        GROUP BY personne_affectations.personne_id
    ),
    lieux_activite AS (
        SELECT personne_id,
        jsonb_agg(
            jsonb_build_object(
                'siret', structure.siret,
                'nom', structure.nom,
                'contact', structure.contact,
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                ),
                'id_carto', structure_cartographie_nationale_id
            )
        ) AS lieux
        FROM main.personne_affectations AS lieux
        INNER JOIN main.structure ON structure.structure_coop_id = lieux.structure_coop_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE personne_id = var_personne_id AND type = 'lieu_activite'
        GROUP BY personne_id
    ),
    is_cn AS (
        SELECT pa.personne_id
        FROM main.personne_affectations pa
        WHERE pa.personne_id = var_personne_id
        AND pa.source = 'idposte'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
        LIMIT 1
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN is_cn.personne_id IS NOT NULL THEN True ELSE False END,
        'pg_id', personne.cn_pg_id,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    LEFT JOIN is_cn ON is_cn.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, is_cn.personne_id;
END;
$function$;

-- ============================================================
-- 2. Vue dataviz.personne : emails et telephone
-- ============================================================
DROP VIEW IF EXISTS dataviz.personne;
CREATE VIEW dataviz.personne AS
WITH lieux AS (
    SELECT lieux_1.personne_id,
        min(qpv.id) AS qpv,
        min(frr.id) AS frr,
        count(*) AS nbr,
        CASE
            WHEN bool_or('France Services' = ANY (structure_1.dispositif_programmes_nationaux)) THEN 'Oui'
            ELSE 'Non'
        END AS est_france_services
    FROM main.personne_affectations lieux_1
        JOIN main.structure structure_1 ON structure_1.id = lieux_1.structure_id
        JOIN main.adresse adresse_1 ON adresse_1.id = structure_1.adresse_id
        LEFT JOIN admin.zonage qpv ON qpv.type = 'QPV' AND st_contains(qpv.geom, adresse_1.geom)
        LEFT JOIN admin.zonage frr ON frr.type = 'FRR' AND adresse_1.code_insee = frr.code_insee
    WHERE lieux_1.type = 'lieu_activite'
    GROUP BY lieux_1.personne_id
), coop AS (
    SELECT activites_coop.personne_id,
        count(*) AS nbr
    FROM main.activites_coop
    GROUP BY activites_coop.personne_id
)
SELECT personne.id AS "Personne ID",
    structure.id AS "Structure employeuse ID",
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    personne.contact -> 'coop' ->> 'telephone' AS "Téléphone",
    concat_ws(', ',
        personne.contact -> 'coop' ->> 'email',
        personne.contact -> 'idposte' ->> 'mail_pro',
        personne.contact -> 'idposte' ->> 'mail_perso'
    ) AS emails,
    CASE
        WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS "Conseiller Numérique",
    CASE
        WHEN personne.is_coordinateur IS TRUE THEN 'Oui'
        WHEN personne.is_coordinateur IS FALSE THEN 'Non'
        ELSE NULL
    END AS "Coordinateur",
    CASE
        WHEN (EXISTS ( SELECT 1
            FROM main.personne_affectations pa
            WHERE pa.personne_id = personne.id AND pa.source = 'aidants-connect' AND pa.est_active = true AND pa.type = 'structure_emploi')) THEN 'Oui'
        WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'
        ELSE NULL
    END AS "Aidants Connect",
    CASE
        WHEN personne.is_mediateur = true THEN 'Médiateur'
        WHEN personne.is_mediateur = false OR personne.is_mediateur IS NULL THEN 'Aidant numérique'
        ELSE NULL
    END AS "Type accompagnateur",
    CASE
        WHEN (EXISTS ( SELECT 1
            FROM main.personne_affectations pa
            WHERE pa.personne_id = personne.id AND pa.type = 'structure_emploi' AND pa.est_active = true)) THEN 'Oui'
        ELSE 'Non'
    END AS "En poste",
    CASE
        WHEN lieux.qpv IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS "QPV",
    CASE
        WHEN lieux.frr IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    structure.nom AS "Structure employeuse",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
    CASE
        WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'
        ELSE 'Non'
    END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE
        WHEN formation.pix IS TRUE THEN 'Oui'
        WHEN formation.pix IS FALSE THEN 'Non'
        ELSE NULL
    END AS "Certification PIX",
    CASE
        WHEN formation.remn IS TRUE THEN 'Oui'
        WHEN formation.remn IS FALSE THEN 'Non'
        ELSE NULL
    END AS "Certification REMN"
FROM main.personne
    LEFT JOIN main.personne_affectations ON personne.id = personne_affectations.personne_id AND personne_affectations.type = 'structure_emploi' AND personne_affectations.est_active = true AND personne_affectations.structure_id IS NOT NULL
    LEFT JOIN main.structure ON personne_affectations.structure_id = structure.id
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.commune ON adresse.code_insee = commune.code_insee
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN lieux ON personne.id = lieux.personne_id
    LEFT JOIN coop ON personne.id = coop.personne_id;

-- ============================================================
-- 3. Vue dataviz.poste : emails personne (structure contact inchange)
-- ============================================================
CREATE OR REPLACE VIEW dataviz.poste AS
SELECT poste.poste_conum_id AS id_poste,
    structure.structure_tp_id AS id_structure,
    personne.cn_pg_id AS id_cn,
    poste.etat,
    poste.date_attribution,
    poste.date_rendu_poste AS date_rendu_de_poste,
    poste.typologie,
    poste.action_coselec,
    poste.origine_transfert,
    structure.nom AS nom_structure,
    structure.siret,
    CASE
        WHEN structure.publique IS TRUE THEN 'Publique'
        ELSE 'Privée'
    END AS "publique/privée",
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
    subvention.date_fin_convention,
    subvention.date_debut_financement AS "date_début_financement",
    subvention.date_fin_financement AS date_de_fin_financement,
    subvention.mois_utilises_periode_financement AS "mois_consommés_sur_la_période_de_financement",
    subvention.mois_utilises_poste AS "mois_consommés_sur_le_poste",
    subvention.montant_subvention AS montant_subventions_hors_bonification,
    CASE
        WHEN subvention.is_territoire_prioritaire IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS territoire_prioritaire,
    subvention.montant_bonification AS "bonification découlant du lieu de permanence",
    subvention.montant_subvention + subvention.montant_bonification AS montant_subventions_total,
    subvention.cp_a_date AS "cp_à_date",
    (subvention.versement_1 + subvention.versement_2 + subvention.versement_3) / (subvention.montant_subvention + subvention.montant_bonification) AS "cp_consommé",
    subvention.montant_subvention + subvention.montant_bonification - (subvention.versement_1 + subvention.versement_2 + subvention.versement_3) AS "reste_à_payer_convention",
    subvention.avoir,
    subvention.versement_1 AS montant_versement_1e_tranche,
    subvention.versement_2 AS montant_versement_2e_tranche,
    subvention.versement_3 AS montant_versement_3e_tranche,
    subvention.date_versement_1 AS date_versement_1e_tranche,
    subvention.date_versement_2 AS date_versement_2e_tranche,
    subvention.date_versement_3 AS date_versement_3e_tranche,
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
    contrat.date_rupture,
    CASE
        WHEN contrat.date_rupture IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS "rupture_anticipée",
    formation.lot,
    formation.marche_formation AS "marché_de_formation",
    formation.label AS formation,
    formation.date_debut AS "date_de_départ",
    formation.date_fin AS date_de_fin,
    formation.lieu,
    formation.parcours,
    formation.observations AS statut_formation_conum,
    NULL::text AS cra,
    CASE
        WHEN poste.poste_renouvele IS TRUE THEN 'Oui'
        WHEN poste.poste_renouvele IS FALSE THEN 'Non'
        ELSE NULL
    END AS "poste_renouvelé",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure,
    structure.contact ->> 'nom' AS "nom_référent_tp",
    structure.contact ->> 'prenom' AS "prénom_référent_tp",
    structure.contact ->> 'telephone' AS telephone,
    (structure.contact -> 'courriels') ->> 'mail_gestionnaire' AS mail_gestionnaire,
    (structure.contact -> 'courriels') ->> 'mail_2' AS mail_2,
    (structure.contact -> 'courriels') ->> 'referent_hierarchique' AS "référent_hiérarchique",
    CASE
        WHEN formation.pix IS TRUE THEN 'Oui'
        WHEN formation.pix IS FALSE THEN 'Non'
        ELSE NULL
    END AS pix,
    CASE
        WHEN formation.remn IS TRUE THEN 'Oui'
        WHEN formation.remn IS FALSE THEN 'Non'
        ELSE NULL
    END AS remn
FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
    JOIN main.poste ON structure.id = poste.structure_id
    LEFT JOIN main.personne ON poste.personne_id = personne.id
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN main.contrat ON contrat.personne_id = personne.id
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id;

-- ============================================================
-- 4. Vue api.carto : email mediateur
-- ============================================================
CREATE OR REPLACE VIEW api.carto AS
WITH courriels AS (
    SELECT structure_1.id,
        string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, 'emails'), key.key), '|') AS courriels_concat
    FROM main.structure structure_1,
        LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, 'emails')) key(key)
    GROUP BY structure_1.id
), personnes AS (
    SELECT sub_table.structure_id,
        jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
    FROM (
        SELECT personne_affectations.structure_id,
            jsonb_build_object(
                'prenom', personne.prenom,
                'nom', personne.nom,
                'label', CASE
                    WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL
                    THEN string_to_array('Conseiller Numerique', ',')
                    ELSE NULL
                END,
                'email', personne.contact -> 'coop' ->> 'email',
                'telephone', personne.contact -> 'coop' ->> 'telephone'
            ) AS mediateurs
        FROM main.personne_affectations
            JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
        WHERE personne_affectations.est_active = true
            AND personne_affectations.type = 'lieu_activite'
            AND (NOT (EXISTS (
                SELECT 1 FROM main.personne_affectations pa2
                WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.est_active = true AND pa2.type = 'structure_emploi'
            )) OR personne.aidant_connect_id IS NULL)
            AND (personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL)
        UNION
        SELECT personne_affectations.structure_id,
            jsonb_build_object(
                'prenom', personne.prenom,
                'nom', personne.nom,
                'label', CASE
                    WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL
                    THEN string_to_array('Conseiller Numerique,Aidant Connect', ',')
                    ELSE string_to_array('Aidant Connect', ',')
                END
            ) AS mediateurs
        FROM main.personne_affectations
            JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
        WHERE personne_affectations.est_active = true
            AND personne_affectations.type = 'lieu_activite'
            AND ((EXISTS (
                SELECT 1 FROM main.personne_affectations pa2
                WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.type = 'structure_emploi'
            )) OR personne.aidant_connect_id IS NOT NULL)
    ) sub_table
    GROUP BY sub_table.structure_id
)
SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000')::varchar(14) AS pivot,
    structure.nom,
    jsonb_build_object('numero_voie', adresse.numero_voie, 'repetition', adresse.repetition, 'nom_voie', adresse.nom_voie, 'code_postal', adresse.code_postal, 'commune', adresse.nom_commune, 'code_insee', adresse.code_insee) AS adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    structure.typologies AS typologie,
    jsonb_extract_path_text(structure.contact, 'telephone') AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, 'site_web') AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source,
    structure.itinerance,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    structure.services,
    structure.publics_specifiquement_adresses,
    structure.prise_en_charge_specifique,
    structure.frais_a_charge,
    structure.dispositif_programmes_nationaux,
    structure.formations_labels,
    structure.autres_formations_labels,
    structure.modalites_acces,
    structure.modalites_accompagnement,
    structure.prise_rdv,
    personnes.mediateurs
FROM main.structure
    LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
    LEFT JOIN courriels ON courriels.id = structure.id
    LEFT JOIN personnes ON personnes.structure_id = structure.id
WHERE structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale;
