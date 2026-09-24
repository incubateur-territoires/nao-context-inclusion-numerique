-- ============================================================
-- V144 – #1805 : main.activites_coop devient une vue sur coop.activites.
-- ============================================================
-- La table répliquée par l'ETL coop-import (API /api/v1/activites, quotidien)
-- divergeait structurellement de la source : suppressions jamais propagées
-- (transformer sans deleted_at, cas constaté lieu 3585 : 207 vs 205),
-- fraîcheur D-1, activités jetées silencieusement quand le médiateur n'avait
-- pas encore d'écho dans main.personne.
-- Le schéma coop cohabite dans le même cluster depuis la bascule Prisma →
-- la table est remplacée par une vue de compatibilité du même nom, lisant
-- coop.activites en direct. Les consommateurs (vues dataviz, loaders MIN,
-- Metabase) gardent le même contrat de colonnes, en temps réel.
--
-- Différences assumées avec la table :
--   - la colonne technique `id` (identity) disparaît (aucun consommateur) ;
--   - created_at/updated_at (timestamps d'ingestion entrepôt) deviennent des
--     alias de creation/modification coop ;
--   - degre_de_finalisation_demarche et thematiques_demarche_administrative
--     (100 % NULL en table) restent exposées à NULL ;
--   - beneficiaires est recalculé depuis coop.accompagnements ×
--     coop.beneficiaires (au lieu du JSON API figé) : toujours renseigné,
--     y compris pour les ~40k lignes legacy où la table portait NULL ;
--   - les labels thematiques perdent leur capitale initiale ("aide aux
--     demarches administratives" et non "Aide aux…") : la transformation par
--     élément (subplan corrélé) coûtait ~10 s sur les agrégats nationaux MIN,
--     la version par opérations de chaîne globales redescend à ~1,5 s. Seul
--     consommateur sensible à la casse : Metabase (abandon acté) — les CASE
--     ILIKE de MIN sont insensibles ;
--   - les activités dont le médiateur n'a pas d'écho dans main.personne sont
--     désormais présentes (personne_id NULL) au lieu d'être absentes.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Drop des 6 vues dataviz dépendantes (recréées à l'identique en §5).
-- ------------------------------------------------------------
DROP VIEW IF EXISTS dataviz.accompagnements;
DROP VIEW IF EXISTS dataviz.lieux_inclusion_numerique;
DROP VIEW IF EXISTS dataviz.personne;
DROP VIEW IF EXISTS dataviz.personne_pseudonymisee;
DROP VIEW IF EXISTS dataviz.personnes_accompagnements;
DROP VIEW IF EXISTS dataviz.zonages;

-- ------------------------------------------------------------
-- 2) Fonctions de fusion qui écrivaient dans la table.
--    merge_structure : legacy cassée depuis V084 (elle référence
--    activites_coop.structure_id, renommée lieu_id) — suppression sèche.
--    merge_personne : recréée sans le repointage activites_coop (la vue suit
--    automatiquement personne.coop_id, consolidé par la fusion elle-même).
--    Les DO blocks inline des DAGs de similarité sont nettoyés dans la même MR.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS main.merge_structure(integer, integer);

CREATE OR REPLACE FUNCTION main.merge_personne(winner_id integer, loser_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    p_winner main.personne;
    p_loser main.personne;
BEGIN
    IF winner_id = loser_id THEN
        RAISE EXCEPTION 'winner_id et loser_id doivent être différents';
    END IF;

    -- Lock les deux personnes
    PERFORM 1 FROM main.personne WHERE id = winner_id FOR UPDATE;
    PERFORM 1 FROM main.personne WHERE id = loser_id FOR UPDATE;

    -- Récupère les données
    SELECT * INTO p_winner FROM main.personne WHERE id = winner_id;
    SELECT * INTO p_loser FROM main.personne WHERE id = loser_id;

    -- 1. Vider les champs uniques sur le loser AVANT de les transférer
    UPDATE main.personne
    SET
        aidant_connect_id = NULL,
        cn_pg_id = NULL,
        conseiller_numerique_id = NULL,
        coop_id = NULL
    WHERE id = loser_id;

    -- 2. Mettre à jour les champs sur le winner (si manquants)
    UPDATE main.personne
    SET
        aidant_connect_id = COALESCE(p_winner.aidant_connect_id, p_loser.aidant_connect_id),
        cn_pg_id = COALESCE(p_winner.cn_pg_id, p_loser.cn_pg_id),
        conseiller_numerique_id = COALESCE(p_winner.conseiller_numerique_id, p_loser.conseiller_numerique_id),
        nb_accompagnements_ac = COALESCE(p_winner.nb_accompagnements_ac, p_loser.nb_accompagnements_ac),
        contact = COALESCE(NULLIF(p_winner.contact, '{}'::jsonb), p_loser.contact),
        profession_ac = COALESCE(p_winner.profession_ac, p_loser.profession_ac),
        is_active_ac = COALESCE(p_winner.is_active_ac, p_loser.is_active_ac),
        is_mediateur = COALESCE(p_winner.is_mediateur, p_loser.is_mediateur),
        coop_id = COALESCE(p_winner.coop_id, p_loser.coop_id)
    WHERE id = winner_id;

    -- 3. Supprimer les doublons potentiels dans personne_affectations
    DELETE FROM main.personne_affectations pa
    USING main.personne_affectations pb
    WHERE pa.personne_id = loser_id
      AND pb.personne_id = winner_id
      AND pa.structure_id = pb.structure_id
      AND pa.type = pb.type
      AND COALESCE(pa.suppression, '1234-01-02 03:04:05+00') = COALESCE(pb.suppression, '1234-01-02 03:04:05+00');

    -- 4. Re-mapper les relations vers le winner
    -- (activites_coop est une vue depuis V144 : elle suit personne.coop_id)
    UPDATE main.personne_affectations SET personne_id = winner_id WHERE personne_id = loser_id;
    UPDATE main.contrat               SET personne_id = winner_id WHERE personne_id = loser_id;
    UPDATE main.formation             SET personne_id = winner_id WHERE personne_id = loser_id;
    UPDATE main.poste                 SET personne_id = winner_id WHERE personne_id = loser_id;

    -- 5. Remplacer dans coordination_mediation les IDs
    UPDATE main.coordination_mediation
    SET
        mediateur_id = winner_id,
        mediateur_coop_id = COALESCE(p_winner.coop_id, p_loser.coop_id)
    WHERE mediateur_id = loser_id;

    UPDATE main.coordination_mediation
    SET
        coordinateur_id = winner_id,
        coordinateur_coop_id = COALESCE(p_winner.coop_id, p_loser.coop_id)
    WHERE coordinateur_id = loser_id;

    -- 6. Supprimer définitivement le loser
    DELETE FROM main.personne WHERE id = loser_id;

    RAISE NOTICE 'Fusion réussie entre winner_id=%, loser_id=%', winner_id, loser_id;
END;
$function$;

-- ------------------------------------------------------------
-- 3) Swap : la table laisse place à la vue de compatibilité.
--    Le silver staging.coop__activites et le retrait du chemin ETL sont
--    traités dans la même MR (coop-dag.py) ; la table silver est droppée
--    ici pour ne pas laisser un artefact orphelin.
-- ------------------------------------------------------------
-- Le silver n'a plus de producteur : drop inconditionnel (IF EXISTS, la table
-- peut ne pas exister selon l'environnement).
DROP TABLE IF EXISTS staging.coop__activites;

-- Bloc défensif (doctrine V108/V142) : le schéma coop appartient à la coop
-- (Prisma) et n'existe pas sur une base neuve (CI test_migration). Dans ce
-- cas le swap est ignoré : main.activites_coop reste une table (vide sur une
-- base neuve), les vues dataviz du §5 pointent indifféremment table ou vue.
DO $swap$
BEGIN
    IF to_regclass('coop.activites') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : swap table -> vue ignoré.';
        RETURN;
    END IF;

    EXECUTE 'DROP TABLE main.activites_coop';

    EXECUTE $vue$
CREATE VIEW main.activites_coop AS
SELECT
    a.id                                                 AS coop_id,
    li.id                                                AS lieu_id,
    p.id                                                 AS personne_id,
    a.type::text                                         AS type,
    a.date,
    a.duree,
    a.lieu_code_insee,
    a.type_lieu::text                                    AS type_lieu,
    replace(a.autonomie::text, '_', ' ')                 AS autonomie,
    replace(a.structure_de_redirection::text, '_', ' ')  AS structure_de_redirection,
    a.oriente_vers_structure,
    a.precisions_demarche,
    NULL::character varying(50)                          AS degre_de_finalisation_demarche,
    a.titre_atelier,
    a.niveau::text                                       AS niveau_atelier,
    a.accompagnements_count                              AS accompagnements,
    CASE WHEN a.thematiques IS NULL OR a.thematiques = '{}' THEN NULL
         ELSE string_to_array(replace(array_to_string(a.thematiques, ','), '_', ' '), ',')
    END                                                  AS thematiques,
    NULLIF(a.materiel::text[], '{}')                     AS materiels,
    NULL::text[]                                         AS thematiques_demarche_administrative,
    a.creation                                           AS created_at,
    a.modification                                       AS updated_at,
    date_trunc('month', a.date)::date                    AS periode,
    a.creation                                           AS created_at_coop,
    a.modification                                       AS updated_at_coop,
    (SELECT jsonb_build_object(
        'total', count(*),
        'genres', jsonb_build_object(
            'feminin',        count(*) FILTER (WHERE b.genre::text = 'feminin'),
            'masculin',       count(*) FILTER (WHERE b.genre::text = 'masculin'),
            'non_communique', count(*) FILTER (WHERE b.genre IS NULL OR b.genre::text = 'non_communique')),
        'statuts', jsonb_build_object(
            'retraite',       count(*) FILTER (WHERE b.statut_social::text = 'retraite'),
            'en_emploi',      count(*) FILTER (WHERE b.statut_social::text = 'en_emploi'),
            'scolarise',      count(*) FILTER (WHERE b.statut_social::text = 'scolarise'),
            'sans_emploi',    count(*) FILTER (WHERE b.statut_social::text = 'sans_emploi'),
            'non_communique', count(*) FILTER (WHERE b.statut_social IS NULL OR b.statut_social::text = 'non_communique')),
        'tranches_age', jsonb_build_object(
            'moins_de_douze',          count(*) FILTER (WHERE b.tranche_age::text = 'moins_de_douze'),
            'douze_dix_huit',          count(*) FILTER (WHERE b.tranche_age::text = 'douze_dix_huit'),
            'dix_huit_vingt_quatre',   count(*) FILTER (WHERE b.tranche_age::text = 'dix_huit_vingt_quatre'),
            'vingt_cinq_trente_neuf',  count(*) FILTER (WHERE b.tranche_age::text = 'vingt_cinq_trente_neuf'),
            'quarante_cinquante_neuf', count(*) FILTER (WHERE b.tranche_age::text = 'quarante_cinquante_neuf'),
            'soixante_soixante_neuf',  count(*) FILTER (WHERE b.tranche_age::text = 'soixante_soixante_neuf'),
            'soixante_dix_plus',       count(*) FILTER (WHERE b.tranche_age::text = 'soixante_dix_plus'),
            'non_communique',          count(*) FILTER (WHERE b.tranche_age IS NULL OR b.tranche_age::text = 'non_communique')))
       FROM coop.accompagnements acc
       JOIN coop.beneficiaires b ON b.id = acc.beneficiaire_id
      WHERE acc.activite_id = a.id)                      AS beneficiaires
FROM coop.activites a
LEFT JOIN main.lieu_inclusion li ON li.structure_coop_id = a.structure_id
LEFT JOIN coop.mediateurs m ON m.id = a.mediateur_id
LEFT JOIN main.personne p ON p.coop_id = m.user_id
WHERE a.suppression IS NULL;
    $vue$;

    EXECUTE $cmt$
COMMENT ON VIEW main.activites_coop IS
    'Vue de compatibilité (V144, #1805) : activités coop lues en direct depuis coop.activites '
    '(suppression IS NULL). Remplace la table répliquée par l''ETL coop-import. '
    'accompagnements = nb de bénéficiaires (1 individuel, N collectif). '
    'lieu_id : main.lieu_inclusion via structure_coop_id ; personne_id : main.personne '
    'via coop.mediateurs.user_id (NULL si médiateur sans écho entrepôt).'
    $cmt$;

    -- Droits : mêmes lecteurs que la table (une vue ne se réplique qu'en
    -- SELECT ; certains rôles n'existent pas sur toutes les bases).
    DECLARE
        r text;
    BEGIN
        FOREACH r IN ARRAY ARRAY['app_python', 'coop', 'min_dev', 'min_scalingo', 'nao_ro'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
                EXECUTE format('GRANT SELECT ON main.activites_coop TO %I', r);
            END IF;
        END LOOP;
    END;
END
$swap$;

-- ------------------------------------------------------------
-- 5) Recréation à l'identique des 6 vues dataviz (définitions courantes),
--    qui lisent désormais coop.activites à travers la vue de compatibilité.
-- ------------------------------------------------------------

CREATE VIEW dataviz.accompagnements AS
 SELECT a.periode,
    t.t AS thematique,
    count(*) AS nb_accompagnements
   FROM main.activites_coop a
     LEFT JOIN LATERAL unnest(COALESCE(a.thematiques, ARRAY[]::text[])) t(t) ON true
  GROUP BY a.periode, t.t
  ORDER BY a.periode;

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
  ORDER BY b.periode, b.role, b.personne_id;

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

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.accompagnements, dataviz.lieux_inclusion_numerique, '
                'dataviz.personne, dataviz.personne_pseudonymisee, '
                'dataviz.personnes_accompagnements, dataviz.zonages TO app_metabase';
    END IF;
END
$$;
