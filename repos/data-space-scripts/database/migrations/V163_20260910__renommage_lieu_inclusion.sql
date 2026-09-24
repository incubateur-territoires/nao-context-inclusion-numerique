-- V163 — SEPT #1724 : RENOMMAGE — main.lieu_inclusion_registre devient main.lieu_inclusion.
--
-- Accord coop du 2026-09-10 (la PR coop #615, non déployée, vise le nouveau nom).
-- La projection triviale V162 disparaît : la TABLE reprend son nom historique et
-- devient l'objet unique que tout le monde lit et écrit. Les contraintes portent
-- déjà les noms historiques (lieu_inclusion_pkey, *_carto_id_ukey, …) : rien à
-- renommer sauf la séquence d'identité. Les vues liées au registre par OID
-- (personne_affectations_lieu, activites_coop, lieu_divergences_coop) suivent le
-- renommage automatiquement.
--
-- Cérémonie (pattern V153) : les 14 vues qui référencent main.lieu_inclusion
-- (liées par OID à la projection) sont droppées, la projection et son trigger
-- INSTEAD OF avec elles (les éditions Prisma MIN frappent désormais la table —
-- le modèle MIN déclare updated_at en dbgenerated, jamais écrit : vérifié),
-- la table est renommée, puis les 14 vues sont recréées à L'IDENTIQUE (leurs
-- définitions résolvent main.lieu_inclusion par nom → la table), avec leurs
-- commentaires et leurs grants. Seule évolution : api.carto exclut désormais
-- les lignes coop supprimées (deleted_at — la projection portait ce filtre ;
-- 0 ligne concernée à ce jour, sémantique nécessaire dès le déploiement coop).
--
-- ⚠️ Séquencement : merger APRÈS !984 et !985 ; la coop ne déploie #615 (qui
-- vise main.lieu_inclusion) qu'après confirmation que CE renommage est en prod.
--
-- Bloc défensif : sur base neuve (CI), V153 n'a jamais basculé — la table
-- s'appelle déjà main.lieu_inclusion, il n'y a ni registre ni projection →
-- migration entièrement ignorée.

DO $mig$
BEGIN
    IF to_regclass('main.lieu_inclusion_registre') IS NULL THEN
        RAISE NOTICE 'Pas de registre (CI/base neuve, nom déjà correct) : V163 ignorée.';
        RETURN;
    END IF;

    -- 1) Drop des 14 vues dépendantes de la projection
    EXECUTE 'DROP VIEW api.aidants_connect';
    EXECUTE 'DROP VIEW api.carto';
    EXECUTE 'DROP VIEW api.carto_departement';
    EXECUTE 'DROP VIEW api.carto_region';
    EXECUTE 'DROP VIEW api.structures';
    EXECUTE 'DROP VIEW dataviz.lieu_appariements_a_valider';
    EXECUTE 'DROP VIEW dataviz.lieux_inclusion_numerique';
    EXECUTE 'DROP VIEW dataviz.personne';
    EXECUTE 'DROP VIEW dataviz.personne_pseudonymisee';
    EXECUTE 'DROP VIEW dataviz.personnes_accompagnements';
    EXECUTE 'DROP VIEW dataviz.structures';
    EXECUTE 'DROP VIEW dataviz.zonages';
    EXECUTE 'DROP VIEW opendata.lieux_geojson';
    EXECUTE 'DROP VIEW opendata.lieux_mednum';

    -- 2) Drop de la projection et de son trigger d'édition MIN
    EXECUTE 'DROP VIEW main.lieu_inclusion';
    EXECUTE 'DROP FUNCTION main.lieu_inclusion_vue_update()';

    -- 3) Renommage de la table et de sa séquence d'identité
    EXECUTE 'ALTER TABLE main.lieu_inclusion_registre RENAME TO lieu_inclusion';
    IF to_regclass('main.lieu_inclusion_registre_id_seq') IS NOT NULL THEN
        EXECUTE 'ALTER SEQUENCE main.lieu_inclusion_registre_id_seq RENAME TO lieu_inclusion_id_seq';
    END IF;

    -- 4) Recréation des 14 vues (définitions identiques — elles se rebindent
    --    sur la table ; api.carto gagne le filtre deleted_at coop)
    EXECUTE $v0$
    CREATE VIEW api.aidants_connect AS
 WITH employeurs AS (
         SELECT DISTINCT ON (candidates.personne_id) candidates.personne_id,
            candidates.structure_id,
            candidates.nom,
            candidates.adresse,
            candidates.code_insee,
            candidates.commune,
            candidates.code_departement
           FROM ( SELECT pae.personne_id,
                    sa.id AS structure_id,
                    sa.denomination_sirene AS nom,
                    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
                    a.code_insee,
                    a.nom_commune AS commune,
                    a.departement AS code_departement,
                    0 AS priority,
                    COALESCE(pae.updated_at, pae.created_at) AS ts,
                    pae.id AS aff_id
                   FROM main.personne_affectations_emploi pae
                     JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
                     LEFT JOIN main.adresse a ON a.id = sa.adresse_id
                  WHERE pae.est_active = true
                UNION ALL
                 SELECT pal.personne_id,
                    li.id AS structure_id,
                    li.nom,
                    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
                    a.code_insee,
                    a.nom_commune AS commune,
                    a.departement AS code_departement,
                    1 AS priority,
                    COALESCE(pal.updated_at, pal.created_at) AS ts,
                    pal.id AS aff_id
                   FROM main.personne_affectations_lieu pal
                     JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
                     LEFT JOIN main.adresse a ON a.id = li.adresse_id
                  WHERE pal.est_active = true) candidates
          ORDER BY candidates.personne_id, candidates.priority, candidates.ts DESC, candidates.aff_id DESC
        )
 SELECT p.aidant_connect_id,
    p.id,
    COALESCE(p.nb_accompagnements_ac, 0) AS nb_accompagnements,
    e.code_insee,
    jsonb_strip_nulls(jsonb_build_object('id', e.structure_id, 'nom', e.nom, 'adresse', e.adresse, 'code_insee', e.code_insee, 'commune', e.commune, 'departement', e.code_departement)) AS structure_employeuse
   FROM main.personne p
     LEFT JOIN employeurs e ON e.personne_id = p.id
  WHERE p.aidant_connect_id IS NOT NULL
    $v0$;
    EXECUTE $v1$
    CREATE VIEW api.carto AS
 WITH courriels AS (
         SELECT li_1.id,
            string_agg(v.value, '|'::text) AS courriels_concat
           FROM main.lieu_inclusion li_1,
            LATERAL jsonb_each_text(jsonb_extract_path(li_1.contact, VARIADIC ARRAY['courriels'::text])) v(key, value)
          WHERE v.key = 'email'::text
          GROUP BY li_1.id
        ), personnes AS (
         SELECT sub.lieu_id,
            jsonb_strip_nulls(jsonb_agg(jsonb_build_object('prenom', sub.prenom, 'nom', sub.nom, 'label', sub.label, 'email', sub.email, 'telephone', sub.telephone))) AS mediateurs
           FROM ( SELECT pal.lieu_id,
                    p.prenom,
                    p.nom,
                    COALESCE((p.contact -> 'coop'::text) ->> 'email'::text, (p.contact -> 'idposte'::text) ->> 'mail_pro'::text, (p.contact -> 'idposte'::text) ->> 'mail_perso'::text) AS email,
                    COALESCE((p.contact -> 'coop'::text) ->> 'telephone'::text, (p.contact -> 'idposte'::text) ->> 'telephone'::text) AS telephone,
                    ARRAY( SELECT labels.lbl
                           FROM ( SELECT 1 AS ord,
                                    'Conseiller Numerique'::text AS lbl
                                  WHERE flags.est_cn
                                UNION ALL
                                 SELECT 2,
                                    'Aidant Connect'::text AS text
                                  WHERE flags.est_ac
                                UNION ALL
                                 SELECT 3,
                                    'Médiateur numérique'::text AS text
                                  WHERE p.is_mediateur = true AND NOT flags.est_cn AND NOT flags.est_ac) labels
                          ORDER BY labels.ord) AS label
                   FROM main.personne_affectations_lieu pal
                     JOIN main.personne p ON p.id = pal.personne_id
                     CROSS JOIN LATERAL ( SELECT p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL AS est_cn,
                            (EXISTS ( SELECT 1
                                   FROM main.personne_affectations_emploi pa_ac
                                  WHERE pa_ac.personne_id = p.id AND pa_ac.source::text = 'aidants-connect'::text AND pa_ac.est_active = true)) AS est_ac,
                            (EXISTS ( SELECT 1
                                   FROM main.personne_affectations_emploi pa_emp
                                  WHERE pa_emp.personne_id = p.id AND pa_emp.est_active = true AND pa_emp.source::text <> 'aidants-connect'::text)) AS a_emploi_actif_non_ac) flags
                  WHERE pal.est_active = true AND p.is_visible IS DISTINCT FROM false AND (flags.est_ac OR flags.est_cn AND flags.a_emploi_actif_non_ac OR p.is_mediateur = true AND NOT flags.est_cn AND NOT flags.est_ac)) sub
          GROUP BY sub.lieu_id
        )
 SELECT li.structure_cartographie_nationale_id AS id,
    '00000000000000'::character varying(14) AS pivot,
    li.nom,
    jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'code_postal', a.code_postal, 'commune', a.nom_commune, 'code_insee', a.code_insee) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    li.typologies AS typologie,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    li.horaires,
    li.presentation_resume,
    li.presentation_detail,
    li.source,
    li.itinerance,
    COALESCE(li.updated_at, li.created_at) AS date_maj,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.prise_rdv,
    personnes.mediateurs
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse a ON a.id = li.adresse_id
     LEFT JOIN courriels ON courriels.id = li.id
     LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL AND li.visible_pour_cartographie_nationale = true
   AND (li.structure_coop_id IS NULL OR li.deleted_at IS NULL)
    $v1$;
    EXECUTE $c1$ COMMENT ON VIEW api.carto IS $t1$ Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion (fin de la photo mednum transitoire V154). `pivot` non renseigné depuis #1711. $t1$ $c1$;
    EXECUTE $v2$
    CREATE VIEW api.carto_departement AS
 SELECT coll_terr.departement_code AS code,
    coll_terr.departement_nom AS nom,
    count(li.id) AS nombre_lieux
   FROM main.lieu_inclusion li
     JOIN main.adresse a ON a.id = li.adresse_id
     JOIN admin.coll_terr ON a.code_insee::text = coll_terr.code_insee::text
  WHERE li.visible_pour_cartographie_nationale
  GROUP BY coll_terr.departement_code, coll_terr.departement_nom
    $v2$;
    EXECUTE $v3$
    CREATE VIEW api.carto_region AS
 SELECT coll_terr.region_code AS code,
    coll_terr.region_nom AS nom,
    count(li.id) AS nombre_lieux
   FROM main.lieu_inclusion li
     JOIN main.adresse a ON a.id = li.adresse_id
     JOIN admin.coll_terr ON a.code_insee::text = coll_terr.code_insee::text
  WHERE li.visible_pour_cartographie_nationale
  GROUP BY coll_terr.region_code, coll_terr.region_nom
    $v3$;
    EXECUTE $v4$
    CREATE VIEW api.structures AS
 SELECT sa.siret,
    sa.rna,
    sa.denomination_sirene AS nom,
    sa.code_activite_principale,
    sa.etat_administratif,
    sa.denomination_sirene,
    sa.categorie_juridique AS code_categorie_juridique,
    cj.nom AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
   FROM main.structure_administrative sa
     LEFT JOIN main.adresse a ON a.id = sa.adresse_id
     LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
UNION ALL
 SELECT NULL::character varying AS siret,
    NULL::character varying AS rna,
    li.nom,
    NULL::character varying AS code_activite_principale,
    NULL::character varying AS etat_administratif,
    NULL::character varying AS denomination_sirene,
    NULL::character varying AS code_categorie_juridique,
    NULL::character varying AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse a ON a.id = li.adresse_id
    $v4$;
    EXECUTE $v5$
    CREATE VIEW dataviz.lieu_appariements_a_valider AS
 SELECT la.id,
    la.carto_segment,
    la.carto_record_id,
    la.source,
    la.carto_nom,
    la.carto_adresse,
    la.carto_commune,
    la.score_nom,
    la.score_adresse,
    la.score_distance,
    la.score_global,
    la.distance_m,
    la.premiere_detection,
    la.derniere_detection,
    l.id AS lieu_id,
    l.nom AS lieu_nom,
    a.numero_voie AS lieu_numero_voie,
    a.nom_voie AS lieu_nom_voie,
    a.nom_commune AS lieu_commune,
    a.code_insee AS lieu_code_insee
   FROM main.lieu_appariement la
     JOIN main.lieu_inclusion l ON l.id = la.lieu_id
     LEFT JOIN main.adresse a ON a.id = l.adresse_id
  WHERE la.statut::text = 'a_valider'::text
    $v5$;
    EXECUTE $v6$
    CREATE VIEW dataviz.lieux_inclusion_numerique AS
 WITH conseillers AS (
         SELECT pal.lieu_id,
            count(*) AS nbr
           FROM main.personne p
             JOIN main.personne_affectations_lieu pal ON pal.personne_id = p.id
          WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL) AND pal.est_active = true
          GROUP BY pal.lieu_id
        ), coop_lieu AS (
         SELECT activites_coop.lieu_id,
            count(*) AS nbr
           FROM main.activites_coop
          GROUP BY activites_coop.lieu_id
        )
 SELECT li.id AS structure_id,
    li.nom,
    NULL::character varying AS siret,
    NULL::character varying AS rna,
    NULL::text AS "catégorie_juridique_de_la_structure",
    NULL::character varying AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    li.presentation_resume AS "présentation_résumée",
    li.presentation_detail AS "présentation_détaillée",
    li.horaires AS horaires_accueil,
    array_to_string(li.services, ', '::text) AS "services_proposés",
    array_to_string(li.dispositif_programmes_nationaux, ', '::text) AS dispositifs_nationaux,
    array_to_string(li.formations_labels::text[] || NULLIF(NULLIF(NULLIF(li.autres_formations_labels, '{ZRR}'::text[]), '{QPV}'::text[]), '{QPV,ZRR}'::text[]), ', '::text) AS formations,
    array_to_string(li.itinerance, ', '::text) AS "itinérance",
    array_to_string(li.modalites_acces, ', '::text) AS "modalités_accès",
    array_to_string(li.modalites_accompagnement, ', '::text) AS "modalités_accompagnement",
    li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coop_lieu.nbr AS nombre_accompagnements,
    array_to_string(li.typologies, ', '::text) AS typologies,
        CASE
            WHEN zonage.type::text = 'QPV'::text THEN zonage.libelle
            ELSE 'Non'::character varying
        END AS qpv,
        CASE
            WHEN zonage.type::text = 'FRR'::text THEN 'Oui'::text
            ELSE 'Non'::text
        END AS frr,
        CASE
            WHEN 'France Services'::main.dispositif_programme_national = ANY (li.dispositif_programmes_nationaux) THEN 'Oui'::text
            ELSE 'Non'::text
        END AS est_france_services,
        CASE
            WHEN li.structure_coop_id IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse ON li.adresse_id = adresse.id
     LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
     LEFT JOIN admin.zonage ON zonage.type::text = 'FRR'::text AND adresse.code_insee::text = zonage.code_insee::text OR zonage.type::text = 'QPV'::text AND st_contains(zonage.geom, adresse.geom)
     LEFT JOIN conseillers ON li.id = conseillers.lieu_id
     LEFT JOIN coop_lieu ON li.id = coop_lieu.lieu_id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    $v6$;
    EXECUTE $v7$
    CREATE VIEW dataviz.personne AS
 WITH lieux AS (
         SELECT pal.personne_id,
            min(qpv.id) AS qpv,
            min(frr.id) AS frr,
            count(*) AS nbr,
                CASE
                    WHEN bool_or('France Services'::main.dispositif_programme_national = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text
                    ELSE 'Non'::text
                END AS est_france_services
           FROM main.personne_affectations_lieu pal
             JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
             JOIN main.adresse adresse_1 ON adresse_1.id = li.adresse_id
             LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV'::text AND st_contains(qpv.geom, adresse_1.geom)
             LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR'::text AND adresse_1.code_insee::text = frr.code_insee::text
          WHERE pal.est_active = true
          GROUP BY pal.personne_id
        ), coop AS (
         SELECT activites_coop.personne_id,
            count(*) AS nbr
           FROM main.activites_coop
          GROUP BY activites_coop.personne_id
        )
 SELECT personne.id AS "Personne ID",
    sa.id AS "Structure employeuse ID",
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    (personne.contact -> 'coop'::text) ->> 'telephone'::text AS "Téléphone",
    concat_ws(', '::text, (personne.contact -> 'coop'::text) ->> 'email'::text, (personne.contact -> 'idposte'::text) ->> 'mail_pro'::text, (personne.contact -> 'idposte'::text) ->> 'mail_perso'::text) AS emails,
        CASE
            WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "Conseiller Numérique",
        CASE
            WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
            WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Coordinateur",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM main.personne_affectations_emploi pae_1
              WHERE pae_1.personne_id = personne.id AND pae_1.source::text = 'aidants-connect'::text AND pae_1.est_active = true)) THEN 'Oui'::text
            WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
            ELSE NULL::text
        END AS "Aidants Connect",
        CASE
            WHEN personne.is_mediateur = true THEN 'Médiateur'::text
            WHEN personne.is_mediateur = false OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
            ELSE NULL::text
        END AS "Type accompagnateur",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM main.personne_affectations_emploi pae_1
              WHERE pae_1.personne_id = personne.id AND pae_1.est_active = true)) THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "En poste",
        CASE
            WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "QPV",
        CASE
            WHEN lieux.frr IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
        CASE
            WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
        CASE
            WHEN formation.pix IS TRUE THEN 'Oui'::text
            WHEN formation.pix IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Certification PIX",
        CASE
            WHEN formation.remn IS TRUE THEN 'Oui'::text
            WHEN formation.remn IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Certification REMN"
   FROM main.personne
     LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = true
     LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
     LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
     LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
     LEFT JOIN main.formation ON personne.id = formation.personne_id
     LEFT JOIN lieux ON personne.id = lieux.personne_id
     LEFT JOIN coop ON personne.id = coop.personne_id
    $v7$;
    EXECUTE $v8$
    CREATE VIEW dataviz.personne_pseudonymisee AS
 WITH lieux AS (
         SELECT pal.personne_id,
            min(qpv.id) AS qpv,
            min(frr.id) AS frr,
            count(*) AS nbr,
                CASE
                    WHEN bool_or('France Services'::main.dispositif_programme_national = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text
                    ELSE 'Non'::text
                END AS est_france_services
           FROM main.personne_affectations_lieu pal
             JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
             JOIN main.adresse adresse_1 ON adresse_1.id = li.adresse_id
             LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV'::text AND st_contains(qpv.geom, adresse_1.geom)
             LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR'::text AND adresse_1.code_insee::text = frr.code_insee::text
          WHERE pal.est_active = true
          GROUP BY pal.personne_id
        ), coop AS (
         SELECT activites_coop.personne_id,
            count(*) AS nbr
           FROM main.activites_coop
          GROUP BY activites_coop.personne_id
        )
 SELECT
        CASE
            WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "Conseiller Numérique",
        CASE
            WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
            WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Coordinateur",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM main.personne_affectations_emploi pae_1
              WHERE pae_1.personne_id = personne.id AND pae_1.source::text = 'aidants-connect'::text AND pae_1.est_active = true)) THEN 'Oui'::text
            WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
            ELSE NULL::text
        END AS "Aidants Connect",
        CASE
            WHEN personne.is_mediateur = true THEN 'Médiateur'::text
            WHEN personne.is_mediateur = false OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
            ELSE NULL::text
        END AS "Type accompagnateur",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM main.personne_affectations_emploi pae_1
              WHERE pae_1.personne_id = personne.id AND pae_1.est_active = true)) THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "En poste",
        CASE
            WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "QPV",
        CASE
            WHEN lieux.frr IS NOT NULL THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
        CASE
            WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text
            ELSE 'Non'::text
        END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
        CASE
            WHEN formation.pix IS TRUE THEN 'Oui'::text
            WHEN formation.pix IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Certification PIX",
        CASE
            WHEN formation.remn IS TRUE THEN 'Oui'::text
            WHEN formation.remn IS FALSE THEN 'Non'::text
            ELSE NULL::text
        END AS "Certification REMN"
   FROM main.personne
     LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = true
     LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
     LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
     LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
     LEFT JOIN main.formation ON personne.id = formation.personne_id
     LEFT JOIN lieux ON personne.id = lieux.personne_id
     LEFT JOIN coop ON personne.id = coop.personne_id
    $v8$;
    EXECUTE $v9$
    CREATE VIEW dataviz.personnes_accompagnements AS
 WITH src AS (
         SELECT p.id AS personne_id,
            p.nom,
            p.prenom,
                CASE
                    WHEN p.cn_pg_id IS NOT NULL THEN 'CoNum'::text
                    WHEN p.cn_pg_id IS NULL AND p.aidant_connect_id IS NULL THEN 'Médiateur'::text
                    ELSE NULL::text
                END AS role,
            a.periode,
            a.type,
            a.autonomie,
            a.type_lieu,
            a.thematiques,
            a.materiels
           FROM main.activites_coop a
             JOIN main.personne p ON p.id = a.personne_id
        ), base AS (
         SELECT src.personne_id,
            src.nom,
            src.prenom,
            src.periode,
            src.role,
            count(*) AS nb_accompagnements
           FROM src
          GROUP BY src.personne_id, src.nom, src.prenom, src.periode, src.role
        ), counts AS (
         SELECT src.personne_id,
            src.periode,
            'type'::text AS dim,
            src.type AS key,
            count(*) AS n
           FROM src
          WHERE src.type IS NOT NULL
          GROUP BY src.personne_id, src.periode, src.type
        UNION ALL
         SELECT src.personne_id,
            src.periode,
            'autonomie'::text AS text,
            src.autonomie,
            count(*) AS count
           FROM src
          WHERE src.autonomie IS NOT NULL
          GROUP BY src.personne_id, src.periode, src.autonomie
        UNION ALL
         SELECT src.personne_id,
            src.periode,
            'type_lieu'::text AS text,
            src.type_lieu,
            count(*) AS count
           FROM src
          WHERE src.type_lieu IS NOT NULL
          GROUP BY src.personne_id, src.periode, src.type_lieu
        UNION ALL
         SELECT s.personne_id,
            s.periode,
            'thematique'::text AS text,
            t.t,
            count(*) AS count
           FROM src s
             LEFT JOIN LATERAL unnest(COALESCE(s.thematiques, ARRAY[]::text[])) t(t) ON true
          WHERE t.t IS NOT NULL
          GROUP BY s.personne_id, s.periode, t.t
        UNION ALL
         SELECT s.personne_id,
            s.periode,
            'materiel'::text AS text,
            m.m,
            count(*) AS count
           FROM src s
             LEFT JOIN LATERAL unnest(COALESCE(s.materiels, ARRAY[]::text[])) m(m) ON true
          WHERE m.m IS NOT NULL
          GROUP BY s.personne_id, s.periode, m.m
        ), zonages AS (
         SELECT a.personne_id,
            a.periode,
            max(
                CASE
                    WHEN z_1.type::text = 'QPV'::text THEN 1
                    ELSE 0
                END)::boolean AS qpv,
            max(
                CASE
                    WHEN z_1.type::text = 'FRR'::text THEN 1
                    ELSE 0
                END)::boolean AS frr
           FROM main.activites_coop a
             JOIN main.lieu_inclusion li ON li.id = a.lieu_id
             JOIN main.adresse addr ON addr.id = li.adresse_id
             JOIN admin.zonage z_1 ON z_1.type::text = 'FRR'::text AND addr.code_insee::text = z_1.code_insee::text OR z_1.type::text = 'QPV'::text AND st_contains(z_1.geom, addr.geom)
          GROUP BY a.personne_id, a.periode
        )
 SELECT b.periode,
    b.personne_id,
    b.nom,
    b.prenom,
    b.role,
    COALESCE(z.qpv, false) AS qpv,
    COALESCE(z.frr, false) AS frr,
    b.nb_accompagnements,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type'::text), '{}'::jsonb) AS type_accompagnement,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'materiel'::text), '{}'::jsonb) AS materiel,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'autonomie'::text), '{}'::jsonb) AS autonomie,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type_lieu'::text), '{}'::jsonb) AS type_lieu,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'thematique'::text), '{}'::jsonb) AS thematique
   FROM base b
     LEFT JOIN counts c ON c.personne_id = b.personne_id AND c.periode = b.periode
     LEFT JOIN zonages z ON z.personne_id = b.personne_id AND z.periode = b.periode
  GROUP BY b.periode, b.personne_id, b.nom, b.prenom, b.role, b.nb_accompagnements, z.qpv, z.frr
  ORDER BY b.periode, b.role, b.personne_id
    $v9$;
    EXECUTE $v10$
    CREATE VIEW dataviz.structures AS
 SELECT sa.id,
    NULL::uuid AS structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    sa.adresse_id,
    NULL::jsonb AS contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    NULL::character varying AS structure_cartographie_nationale_id,
    NULL::boolean AS visible_pour_cartographie_nationale,
    NULL::main.typologie[] AS typologies,
    NULL::text AS presentation_resume,
    NULL::text AS presentation_detail,
    NULL::character varying AS horaires,
    NULL::character varying AS prise_rdv,
    NULL::main.service[] AS services,
    NULL::main.public_specifiquement_adresse[] AS publics_specifiquement_adresses,
    NULL::main.prise_en_charge_specifique[] AS prise_en_charge_specifique,
    NULL::main.frais_a_charge[] AS frais_a_charge,
    NULL::main.dispositif_programme_national[] AS dispositif_programmes_nationaux,
    NULL::main.formation_label[] AS formations_labels,
    NULL::text[] AS autres_formations_labels,
    NULL::main.itinerance[] AS itinerance,
    NULL::main.modalite_acces[] AS modalites_acces,
    NULL::main.modalite_accompagnement[] AS modalites_accompagnement,
    NULL::integer AS mediateurs_en_activite,
    NULL::integer AS emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    NULL::character varying AS fiche_acces_libre,
    sa.edited_by,
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
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
   FROM main.structure_administrative sa
     LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
     LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
     LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
     LEFT JOIN admin.zonage ON zonage.type::text = 'FRR'::text AND adresse.code_insee::text = zonage.code_insee::text OR zonage.type::text = 'QPV'::text AND st_contains(zonage.geom, adresse.geom)
UNION ALL
 SELECT li.id,
    li.structure_coop_id,
    NULL::uuid AS structure_ac_id,
    NULL::integer AS structure_tp_id,
    li.nom,
    NULL::character varying AS denomination_sirene,
    NULL::character varying AS siret,
    NULL::character varying AS rna,
    li.adresse_id,
    li.contact,
    NULL::character varying AS etat_administratif,
    NULL::character varying AS code_activite_principale,
    NULL::character varying AS categorie_juridique,
    NULL::integer AS nb_mandats_ac,
    NULL::boolean AS publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    NULL::date AS last_sirene_enrich_at,
    li.created_at,
    li.updated_at,
    li.fiche_acces_libre,
    li.edited_by,
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
    NULL::text AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
     LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
     LEFT JOIN admin.zonage ON zonage.type::text = 'FRR'::text AND adresse.code_insee::text = zonage.code_insee::text OR zonage.type::text = 'QPV'::text AND st_contains(zonage.geom, adresse.geom)
    $v10$;
    EXECUTE $v11$
    CREATE VIEW dataviz.zonages AS
 WITH adresses AS (
         SELECT adresse.id AS adresse_id,
            adresse.code_insee,
                CASE
                    WHEN max(zone_qpv.id) > 0 THEN true
                    ELSE false
                END AS qpv,
                CASE
                    WHEN max(zone_frr.id) > 0 THEN true
                    ELSE false
                END AS frr
           FROM main.adresse
             LEFT JOIN admin.zonage zone_qpv ON st_contains(zone_qpv.geom, adresse.geom) AND zone_qpv.type::text = 'QPV'::text
             LEFT JOIN admin.zonage zone_frr ON zone_frr.code_insee::text = adresse.code_insee::text AND zone_frr.type::text = 'FRR'::text
          GROUP BY adresse.id
         HAVING max(zone_qpv.id) > 0 OR max(zone_frr.id) > 0
        ), structures AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            count(*) AS nbr
           FROM main.structure_administrative sa
             JOIN adresses adresse ON adresse.adresse_id = sa.adresse_id
          GROUP BY adresse.code_insee
        ), lieux AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            count(*) AS nbr
           FROM main.lieu_inclusion li
             JOIN adresses adresse ON adresse.adresse_id = li.adresse_id AND li.visible_pour_cartographie_nationale
          GROUP BY adresse.code_insee
        ), activites AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            sum(activites_coop.accompagnements) AS nbr
           FROM main.activites_coop
             JOIN main.lieu_inclusion li ON li.id = activites_coop.lieu_id
             JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
          WHERE li.visible_pour_cartographie_nationale
          GROUP BY adresse.code_insee
        ), activites_conum AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            sum(activites_coop.accompagnements) AS nbr
           FROM main.activites_coop
             JOIN main.lieu_inclusion li ON li.id = activites_coop.lieu_id
             JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
             JOIN main.personne ON personne.id = activites_coop.personne_id
          WHERE li.visible_pour_cartographie_nationale AND personne.conseiller_numerique_id IS NOT NULL
          GROUP BY adresse.code_insee
        ), personnes AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            count(DISTINCT pal.personne_id) AS nbr
           FROM main.personne_affectations_lieu pal
             JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
             JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
          WHERE li.visible_pour_cartographie_nationale AND pal.est_active = true
          GROUP BY adresse.code_insee
        ), personnes_conum AS (
         SELECT adresse.code_insee,
                CASE
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) = 0 THEN 'QPV'::text
                    WHEN max(adresse.qpv::integer) = 0 AND max(adresse.frr::integer) > 0 THEN 'FRR'::text
                    WHEN max(adresse.qpv::integer) > 0 AND max(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                    ELSE NULL::text
                END AS zonage,
            count(DISTINCT pal.personne_id) AS nbr
           FROM main.personne_affectations_lieu pal
             JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
             JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
             JOIN main.personne ON personne.id = pal.personne_id
          WHERE li.visible_pour_cartographie_nationale AND pal.est_active = true AND personne.conseiller_numerique_id IS NOT NULL
          GROUP BY adresse.code_insee
        ), zonages AS (
         SELECT t.zonage
           FROM ( VALUES ('QPV'::text), ('FRR'::text), ('QPV & FRR'::text)) t(zonage)
        )
 SELECT coll_terr.region_nom AS region,
    coll_terr.departement_code AS code_departement,
    coll_terr.departement_nom AS departement,
    coll_terr.code_insee,
    coll_terr.commune_nom AS commune,
    zonages.zonage,
    structures.nbr AS nbr_structures,
    lieux.nbr AS nbr_lieux,
    activites.nbr AS nbr_accompagnements,
    activites_conum.nbr AS nbr_accompagnements_conum,
    personnes.nbr AS nbr_personnes,
    personnes_conum.nbr AS nbr_conseillers_numerique
   FROM admin.coll_terr
     CROSS JOIN zonages
     LEFT JOIN structures ON structures.code_insee::text = coll_terr.code_insee::text AND structures.zonage = zonages.zonage
     LEFT JOIN lieux ON lieux.code_insee::text = coll_terr.code_insee::text AND lieux.zonage = zonages.zonage
     LEFT JOIN activites ON activites.code_insee::text = coll_terr.code_insee::text AND activites.zonage = zonages.zonage
     LEFT JOIN activites_conum ON activites_conum.code_insee::text = coll_terr.code_insee::text AND activites_conum.zonage = zonages.zonage
     LEFT JOIN personnes ON personnes.code_insee::text = coll_terr.code_insee::text AND personnes.zonage = zonages.zonage
     LEFT JOIN personnes_conum ON personnes_conum.code_insee::text = coll_terr.code_insee::text AND personnes_conum.zonage = zonages.zonage
  WHERE structures.nbr IS NOT NULL OR lieux.nbr IS NOT NULL OR activites.nbr IS NOT NULL OR activites_conum.nbr IS NOT NULL OR personnes.nbr IS NOT NULL OR personnes_conum.nbr IS NOT NULL
  GROUP BY coll_terr.region_nom, coll_terr.departement_code, coll_terr.departement_nom, coll_terr.code_insee, coll_terr.commune_nom, zonages.zonage, structures.nbr, lieux.nbr, activites.nbr, activites_conum.nbr, personnes.nbr, personnes_conum.nbr
  ORDER BY coll_terr.departement_code, coll_terr.code_insee, zonages.zonage
    $v11$;
    EXECUTE $v12$
    CREATE VIEW opendata.lieux_geojson AS
 WITH features AS (
         SELECT a.geom,
            li.structure_cartographie_nationale_id,
            NULL::character varying AS siret,
            NULL::character varying AS rna,
            li.nom,
            jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'complement_adresse', li.complement_adresse, 'code_postal', a.code_postal, 'nom_commune', a.nom_commune, 'code_insee', a.code_insee, 'clef_interop', a.clef_interop, 'code_ban', a.code_ban) AS adresse,
            li.typologies,
            jsonb_strip_nulls(jsonb_build_object('telephone', li.contact -> 'telephone'::text, 'site_web', li.contact -> 'site_web'::text, 'courriels', ( SELECT jsonb_object_agg(v.key, v.value) AS jsonb_object_agg
                   FROM jsonb_each(li.contact -> 'courriels'::text) v(key, value)
                  WHERE v.key = 'email'::text))) AS contacts,
            li.horaires,
            li.presentation_resume,
            li.presentation_detail,
            li.source,
            li.itinerance,
            li.services,
            li.publics_specifiquement_adresses,
            li.prise_en_charge_specifique,
            li.frais_a_charge,
            li.dispositif_programmes_nationaux,
            li.formations_labels,
            li.autres_formations_labels,
            li.modalites_acces,
            li.modalites_accompagnement,
            li.fiche_acces_libre,
            li.prise_rdv
           FROM main.lieu_inclusion li
             LEFT JOIN main.adresse a ON li.adresse_id = a.id
          WHERE li.deleted_at IS NULL AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale)
        )
 SELECT jsonb_build_object('type', 'FeatureCollection', 'features', json_agg(st_asgeojson(features.*)::jsonb)) AS jsonb_build_object
   FROM features
    $v12$;
    EXECUTE $c12$ COMMENT ON VIEW opendata.lieux_geojson IS $t12$ Export GeoJSON opendata — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion. $t12$ $c12$;
    EXECUTE $v13$
    CREATE VIEW opendata.lieux_mednum AS
 SELECT li.structure_cartographie_nationale_id AS id,
    '00000000000000'::character varying(14) AS pivot,
    li.nom,
    a.nom_commune AS commune,
    a.code_postal,
    a.code_insee,
    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
    li.complement_adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    array_to_string(li.typologies, '|'::text) AS typologie,
    li.contact ->> 'telephone'::text AS telephone,
    ( SELECT string_agg(v.value, '|'::text) AS string_agg
           FROM jsonb_each_text(li.contact -> 'courriels'::text) v(key, value)
          WHERE v.key = 'email'::text) AS courriels,
    li.contact ->> 'site_web'::text AS site_web,
    li.horaires,
    li.presentation_resume,
    li.presentation_detail,
    li.source,
    array_to_string(li.itinerance, '|'::text) AS itinerance,
    NULL::text AS structure_parente,
    COALESCE(li.updated_at, li.created_at) AS date_maj,
    array_to_string(li.services, '|'::text) AS services,
    array_to_string(li.publics_specifiquement_adresses, '|'::text) AS publics_specifiquement_adresses,
    array_to_string(li.prise_en_charge_specifique, '|'::text) AS prise_en_charge_specifique,
    array_to_string(li.frais_a_charge, '|'::text) AS frais_a_charge,
    array_to_string(li.dispositif_programmes_nationaux, '|'::text) AS dispositif_programmes_nationaux,
    array_to_string(li.formations_labels, '|'::text) AS formations_labels,
    array_to_string(li.autres_formations_labels, '|'::text) AS autres_formations_labels,
    array_to_string(li.modalites_acces, '|'::text) AS modalites_acces,
    array_to_string(li.modalites_accompagnement, '|'::text) AS modalites_accompagnement,
    li.fiche_acces_libre,
    li.prise_rdv
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse a ON li.adresse_id = a.id
  WHERE li.deleted_at IS NULL AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale)
    $v13$;
    EXECUTE $c13$ COMMENT ON VIEW opendata.lieux_mednum IS $t13$ Export opendata (data.gouv) — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion. $t13$ $c13$;

    -- 5) Grants (perdus au DROP), conditionnels à l'existence des rôles
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_incub') THEN
        EXECUTE 'GRANT SELECT ON api.aidants_connect TO postgrest_anct_incub';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto') THEN
        EXECUTE 'GRANT SELECT ON api.carto TO postgrest_anct_carto';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_data_incl') THEN
        EXECUTE 'GRANT SELECT ON api.carto TO postgrest_anct_data_incl';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto') THEN
        EXECUTE 'GRANT SELECT ON api.carto_departement TO postgrest_anct_carto';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto') THEN
        EXECUTE 'GRANT SELECT ON api.carto_region TO postgrest_anct_carto';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_dev') THEN
        EXECUTE 'GRANT SELECT ON api.structures TO postgrest_anct_dev';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.lieu_appariements_a_valider TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.lieux_inclusion_numerique TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.personne TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.personne_pseudonymisee TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.personnes_accompagnements TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.structures TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.zonages TO app_metabase';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_python') THEN
        EXECUTE 'GRANT SELECT ON opendata.lieux_geojson TO app_python';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_python') THEN
        EXECUTE 'GRANT SELECT ON opendata.lieux_mednum TO app_python';
    END IF;
END $mig$;

NOTIFY pgrst, 'reload schema';
