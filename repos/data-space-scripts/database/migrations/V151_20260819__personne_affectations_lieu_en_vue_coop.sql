-- V151 : main.personne_affectations_lieu devient une VUE sur
-- coop.mediateurs_en_activite (source de vérité coop). SEPT #1724, étape 2
-- de la refonte lieux — précédent : V144 (main.activites_coop → vue).
--
-- Pourquoi : la table était répliquée par le coop-dag depuis l'API coop
-- (reset global + upsert par run) → lag d'un jour et divergences (mesure
-- 2026-08-19 : 25 paires actives côté coop absentes de la réplique, 284
-- liens morts côté réplique — utilisateurs supprimés ou liens hard-deleted
-- par le job de dédup coop ; 0 divergence d'est_active sur les paires
-- communes). La vue lit la source en direct : plus de réplication, plus de
-- divergence possible. L'écriture correspondante du coop-dag est retirée
-- dans la même MR.
--
-- Sémantique reproduite à l'identique (contrat de la table) :
--   - une ligne par (personne, lieu, source='coop') ;
--   - est_active = au moins une période d'activité non supprimée et non
--     terminée (fin absente ou future) — équivalent du « l'actif gagne »
--     du dag ;
--   - created_at/updated_at = min(creation)/max(modification) des périodes
--     (api.aidants_connect s'en sert pour prioriser l'employeur) ;
--   - id entier déterministe (row_number) : aucun consommateur ne le
--     persiste (tiebreak/DISTINCT uniquement), Prisma MIN exige un Int.
--
-- Non destructif : la table est renommée _legacy (gel), drop dans une
-- migration ultérieure après validation en prod.
--
-- ⚠️ Les 6 vues dépendantes (liées par OID, elles suivraient la table
-- renommée) sont droppées puis recréées À L'IDENTIQUE (pg_get_viewdef du
-- 2026-08-19) : api.carto (V147), api.aidants_connect (V123),
-- dataviz.lieux_inclusion_numerique / personne / personne_pseudonymisee /
-- zonages (V144). Les fonctions api.get_carto_mediateur / get_mediateur
-- résolvent par nom à l'exécution : rien à faire.
--
-- Bloc défensif (doctrine V108/V142/V144) : le schéma coop appartient à la
-- coop (Prisma) et n'existe pas sur une base neuve (CI test_migration).
-- Dans ce cas le swap ENTIER est ignoré : la table reste une table (vide),
-- les vues dépendantes restent branchées dessus.

DO $swap$
DECLARE
    r text;
BEGIN
    IF to_regclass('coop.mediateurs_en_activite') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : swap table -> vue ignoré.';
        RETURN;
    END IF;

    -- 1) Drop des vues dépendantes
    EXECUTE 'DROP VIEW api.carto';
    EXECUTE 'DROP VIEW api.aidants_connect';
    EXECUTE 'DROP VIEW dataviz.lieux_inclusion_numerique';
    EXECUTE 'DROP VIEW dataviz.personne';
    EXECUTE 'DROP VIEW dataviz.personne_pseudonymisee';
    EXECUTE 'DROP VIEW dataviz.zonages';

    -- 2) Gel de la table répliquée
    EXECUTE 'ALTER TABLE main.personne_affectations_lieu '
            'RENAME TO personne_affectations_lieu_legacy';

    EXECUTE $cmt_legacy$
    COMMENT ON TABLE main.personne_affectations_lieu_legacy IS
        'GELÉE (V151, SEPT #1724) : ancienne réplique coop-dag des affectations '
        'lieu, remplacée par la vue main.personne_affectations_lieu sur '
        'coop.mediateurs_en_activite. Plus écrite ni lue. Drop prévu dans une '
        'migration ultérieure.';
    $cmt_legacy$;

    -- 3) La vue de remplacement (iso-schéma)
    EXECUTE $vue_pal$
    CREATE VIEW main.personne_affectations_lieu AS
    SELECT (row_number() OVER (ORDER BY p.id, l.id))::integer AS id,
           p.id AS personne_id,
           l.id AS lieu_id,
           'coop'::character varying AS source,
           bool_or(mea.suppression IS NULL
                   AND (mea.fin_activite IS NULL OR mea.fin_activite > now())
           ) AS est_active,
           min(mea.creation)     AS created_at,
           max(mea.modification) AS updated_at
    FROM coop.mediateurs_en_activite mea
    JOIN coop.mediateurs m     ON m.id = mea.mediateur_id
    JOIN main.personne p       ON p.coop_id = m.user_id
    JOIN main.lieu_inclusion l ON l.structure_coop_id = mea.structure_id
    GROUP BY p.id, l.id;
    $vue_pal$;

    EXECUTE $cmt_pal$
    COMMENT ON VIEW main.personne_affectations_lieu IS
        'Affectations lieu des médiateurs, lues en direct dans '
        'coop.mediateurs_en_activite (V151, SEPT #1724 — remplace la réplique '
        'coop-dag). est_active = au moins une période non supprimée et non '
        'terminée. personne_id via coop.mediateurs.user_id = personne.coop_id ; '
        'lieu_id via lieu_inclusion.structure_coop_id. source constante ''coop''.';
    $cmt_pal$;

    -- Droits : mêmes lecteurs que la table (une vue ne s'accorde qu'en SELECT ;
    -- certains rôles n'existent pas sur toutes les bases).
    FOREACH r IN ARRAY ARRAY['app_python', 'coop', 'min_dev', 'min_scalingo', 'nao_ro'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('GRANT SELECT ON main.personne_affectations_lieu TO %I', r);
        END IF;
    END LOOP;

    -- 4) Recréation à l'identique des vues dépendantes

    EXECUTE $vue0$
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
                                    'Aidant Connect'::text
                                  WHERE flags.est_ac
                                UNION ALL
                                 SELECT 3,
                                    'Médiateur numérique'::text
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
  WHERE li.structure_cartographie_nationale_id IS NOT NULL AND li.visible_pour_cartographie_nationale = true;
    $vue0$;

    EXECUTE $vue1$
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
  WHERE p.aidant_connect_id IS NOT NULL;
    $vue1$;

    EXECUTE $vue2$
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
  WHERE li.structure_cartographie_nationale_id IS NOT NULL;
    $vue2$;

    EXECUTE $vue3$
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
     LEFT JOIN coop ON personne.id = coop.personne_id;
    $vue3$;

    EXECUTE $vue4$
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
     LEFT JOIN coop ON personne.id = coop.personne_id;
    $vue4$;

    EXECUTE $vue5$
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
  ORDER BY coll_terr.departement_code, coll_terr.code_insee, zonages.zonage;
    $vue5$;


    EXECUTE $cmt_carto$
    COMMENT ON VIEW api.carto IS
        'Vue cartographie publique. Source : main.lieu_inclusion. Depuis #1711 le '
        'lien lieu ↔ structure_administrative est supprimé : `pivot` (SIRET/RNA) '
        'n''est plus renseigné (fallback 00000000000000). Médiateurs : une ligne '
        'par personne (personne_affectations_lieu), labels cumulés CN/AC/Médiateur.';
    $cmt_carto$;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto') THEN
        EXECUTE 'GRANT SELECT ON api.carto TO postgrest_anct_carto';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_data_incl') THEN
        EXECUTE 'GRANT SELECT ON api.carto TO postgrest_anct_data_incl';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_incub') THEN
        EXECUTE 'GRANT SELECT ON api.aidants_connect TO postgrest_anct_incub';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.lieux_inclusion_numerique, '
                'dataviz.personne, dataviz.personne_pseudonymisee, '
                'dataviz.zonages TO app_metabase';
    END IF;
END
$swap$;

NOTIFY pgrst, 'reload schema';
