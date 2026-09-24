-- V162 — SEPT #1724 : BASCULE — main.lieu_inclusion est servie depuis la TABLE.
--
-- Décision 2026-09-09 : le référentiel des lieux est une table matérialisée
-- (main.lieu_inclusion_registre, alimentée par V160 + la double écriture coop
-- PR #615 + les flux), plus une vue d'union calculée en direct. La vue V153
-- (2 branches, jointure coop live, compteur calculé) est remplacée EN PLACE
-- (CREATE OR REPLACE — mêmes 38 colonnes, même ordre) par une projection
-- TRIVIALE de la table : les 15 vues dépendantes, Prisma MIN et le trigger
-- INSTEAD OF (éditions MIN) survivent tels quels ; la table physique garde son
-- nom (le @@map de la PR coop #615 pointe dessus) — le renommage éventuel
-- registre → lieu_inclusion est un nettoyage ultérieur, coordonné avec la coop.
--
-- Alignements de données à la bascule (ce que la vue calculait, la table doit
-- le PORTER) :
--   * visible_pour_cartographie_nationale (lignes coop) := drapeau coop.
--     La vue servait « cycle de vie carto ET drapeau coop » ; le cycle de vie
--     carto n'écrit plus les lignes coop (cette MR, cas 4) et la double
--     écriture coop posera le drapeau. Mesuré sur dev : 1 018 lieux voulus
--     visibles récupèrent leur visibilité (les « 524 » d'août + les réparés du
--     filet) — AUCUN n'a de carto_id → api.carto INCHANGÉE ; ils entrent dans
--     l'export opendata (photo complète, cible cas 4). 20 flips inverses (déjà
--     masqués par le AND de la vue : rien ne change à l'écran pour eux).
--   * mediateurs_en_activite (lignes coop) := compte réel — puis rafraîchi
--     quotidiennement par le filet (registre_lieux_coop.py, fraîcheur J+1
--     assumée pour un compteur).
--   * Le reste est déjà matérialisé par V160 (0 divergence mesurée, V161).
--
-- La projection filtre les lignes coop supprimées (deleted_at posé par la
-- double écriture/le miroir) — iso vue V153 (WHERE cl.suppression IS NULL) ;
-- les lignes externes archivées restent servies (iso branche 2).
--
-- V154 (photo mednum sur l'export public) est ABROGÉE dans la foulée :
-- api.carto, opendata.lieux_mednum et opendata.lieux_geojson reviennent à la
-- lecture pure de main.lieu_inclusion — le référentiel porte la vérité pour
-- tous les consommateurs, api.carto redevient LA photo du dataspace
-- (posture transitoire refermée, divergence api↔MIN éteinte).
--
-- Bloc défensif (doctrine V144/V151/V153) : sur base neuve (CI), V153 n'a pas
-- basculé (main.lieu_inclusion y est restée une table, pas de registre) →
-- partie A ignorée. La partie B (vues d'export) s'applique partout.

-- ======================================================================
-- A) Alignement + projection triviale (uniquement si la bascule V153 a eu lieu)
-- ======================================================================
DO $mig$
BEGIN
    IF to_regclass('main.lieu_inclusion_registre') IS NULL
       OR to_regclass('coop.lieu_inclusion') IS NULL THEN
        RAISE NOTICE 'Registre ou schéma coop absent (CI/base neuve) : partie A ignorée.';
        RETURN;
    END IF;

    -- A1) Alignements
    EXECUTE $al$
    UPDATE main.lieu_inclusion_registre r
    SET visible_pour_cartographie_nationale = cl.visible_pour_cartographie_nationale,
        mediateurs_en_activite = COALESCE(calc.cnt, 0)
    FROM coop.lieu_inclusion cl
    LEFT JOIN LATERAL (
        SELECT count(*)::integer AS cnt
        FROM coop.mediateurs_en_activite mea
        WHERE mea.structure_id = cl.id
          AND mea.suppression IS NULL
          AND mea.fin_activite IS NULL) calc ON TRUE
    WHERE cl.id = r.structure_coop_id
      AND cl.suppression IS NULL
    $al$;

    -- A2) Projection triviale (mêmes colonnes, même ordre que la vue V153 ;
    --     nom recasté en varchar sans typmod — seule différence de type).
    --     Le trigger INSTEAD OF lieu_inclusion_vue_update_tg survit au
    --     CREATE OR REPLACE : les UPDATE Prisma MIN continuent de fonctionner
    --     — et deviennent effectifs sur les lieux coop (la limitation V153
    --     « édition MIN sur lieu coop invisible » disparaît : la table est
    --     servie).
    EXECUTE $v$
    CREATE OR REPLACE VIEW main.lieu_inclusion AS
    SELECT r.id,
           r.old_main_structure_id,
           r.nom::character varying AS nom,
           r.adresse_id,
           r.structure_cartographie_nationale_id,
           r.visible_pour_cartographie_nationale,
           r.fiche_acces_libre,
           r.presentation_resume,
           r.presentation_detail,
           r.horaires,
           r.prise_rdv,
           r.itinerance,
           r.services,
           r.modalites_acces,
           r.modalites_accompagnement,
           r.publics_specifiquement_adresses,
           r.prise_en_charge_specifique,
           r.frais_a_charge,
           r.formations_labels,
           r.autres_formations_labels,
           r.dispositif_programmes_nationaux,
           r.typologies,
           r.contact,
           r.mediateurs_en_activite,
           r.emplois,
           r.source,
           r.edited_by,
           r.created_at,
           r.structure_coop_id,
           r.import_warnings,
           r.updated_at_carto,
           r.updated_at_coop,
           r.updated_at_min,
           r.updated_at,
           r.complement_adresse,
           r.siret_a_l_enrichissement,
           r.nom_usage,
           r.deleted_at
    FROM main.lieu_inclusion_registre r
    WHERE r.structure_coop_id IS NULL OR r.deleted_at IS NULL
    $v$;

    EXECUTE $cmt$
    COMMENT ON VIEW main.lieu_inclusion IS
        'SEPT #1724 (V162) — projection TRIVIALE du référentiel matérialisé '
        'main.lieu_inclusion_registre (alimenté par la double écriture coop, '
        'les flux carto/MIN et le filet). Filtre : lignes coop supprimées '
        'exclues. Le nom lieu_inclusion est conservé pour les consommateurs ; '
        'éditions MIN via trigger INSTEAD OF.'
    $cmt$;
END $mig$;

-- ======================================================================
-- B) Abrogation de V154 : l'export public lit main.lieu_inclusion, point.
--    (Définitions = état pré-V154 ; aucune de ces 3 vues n'a de dépendant.)
-- ======================================================================

DROP VIEW api.carto;
DROP VIEW opendata.lieux_mednum;
DROP VIEW opendata.lieux_geojson;

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
    FROM (
        SELECT pal.lieu_id,
               p.prenom,
               p.nom,
               COALESCE((p.contact -> 'coop'::text) ->> 'email'::text, (p.contact -> 'idposte'::text) ->> 'mail_pro'::text, (p.contact -> 'idposte'::text) ->> 'mail_perso'::text) AS email,
               COALESCE((p.contact -> 'coop'::text) ->> 'telephone'::text, (p.contact -> 'idposte'::text) ->> 'telephone'::text) AS telephone,
               ARRAY(
                   SELECT labels.lbl
                   FROM (
                       SELECT 1 AS ord, 'Conseiller Numerique'::text AS lbl WHERE flags.est_cn
                       UNION ALL
                       SELECT 2, 'Aidant Connect'::text WHERE flags.est_ac
                       UNION ALL
                       SELECT 3, 'Médiateur numérique'::text
                       WHERE p.is_mediateur = true AND NOT flags.est_cn AND NOT flags.est_ac
                   ) labels
                   ORDER BY labels.ord) AS label
        FROM main.personne_affectations_lieu pal
        JOIN main.personne p ON p.id = pal.personne_id
        CROSS JOIN LATERAL (
            SELECT p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL AS est_cn,
                   (EXISTS (SELECT 1 FROM main.personne_affectations_emploi pa_ac
                            WHERE pa_ac.personne_id = p.id AND pa_ac.source::text = 'aidants-connect'::text AND pa_ac.est_active = true)) AS est_ac,
                   (EXISTS (SELECT 1 FROM main.personne_affectations_emploi pa_emp
                            WHERE pa_emp.personne_id = p.id AND pa_emp.est_active = true AND pa_emp.source::text <> 'aidants-connect'::text)) AS a_emploi_actif_non_ac
        ) flags
        WHERE pal.est_active = true
          AND p.is_visible IS DISTINCT FROM false
          AND (flags.est_ac OR flags.est_cn AND flags.a_emploi_actif_non_ac
               OR p.is_mediateur = true AND NOT flags.est_cn AND NOT flags.est_ac)
    ) sub
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
WHERE li.structure_cartographie_nationale_id IS NOT NULL
  AND li.visible_pour_cartographie_nationale = true;

COMMENT ON VIEW api.carto IS
    'Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : '
    'lecture pure du référentiel main.lieu_inclusion (fin de la photo mednum '
    'transitoire V154). `pivot` non renseigné depuis #1711.';

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
    (SELECT string_agg(v.value, '|'::text)
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
WHERE li.deleted_at IS NULL
  AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale);

COMMENT ON VIEW opendata.lieux_mednum IS
    'Export opendata (data.gouv) — LA photo du dataspace (V162, SEPT #1724) : '
    'lecture pure du référentiel main.lieu_inclusion.';

CREATE VIEW opendata.lieux_geojson AS
WITH features AS (
    SELECT a.geom,
           li.structure_cartographie_nationale_id,
           NULL::character varying AS siret,
           NULL::character varying AS rna,
           li.nom,
           jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'complement_adresse', li.complement_adresse, 'code_postal', a.code_postal, 'nom_commune', a.nom_commune, 'code_insee', a.code_insee, 'clef_interop', a.clef_interop, 'code_ban', a.code_ban) AS adresse,
           li.typologies,
           jsonb_strip_nulls(jsonb_build_object(
               'telephone', li.contact -> 'telephone'::text,
               'site_web', li.contact -> 'site_web'::text,
               'courriels', (SELECT jsonb_object_agg(v.key, v.value)
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
    WHERE li.deleted_at IS NULL
      AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale)
)
SELECT jsonb_build_object('type', 'FeatureCollection', 'features', json_agg(st_asgeojson(features.*)::jsonb)) AS jsonb_build_object
FROM features;

COMMENT ON VIEW opendata.lieux_geojson IS
    'Export GeoJSON opendata — LA photo du dataspace (V162, SEPT #1724) : '
    'lecture pure du référentiel main.lieu_inclusion.';

DO $grants$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_carto') THEN
        GRANT SELECT ON api.carto TO postgrest_anct_carto;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_data_incl') THEN
        GRANT SELECT ON api.carto TO postgrest_anct_data_incl;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_python') THEN
        GRANT SELECT ON opendata.lieux_mednum, opendata.lieux_geojson TO app_python;
    END IF;
END
$grants$;

NOTIFY pgrst, 'reload schema';
