-- V164 — SEPT #1868 : api.carto lit les coordonnées et la visibilité des
-- médiateurs EN DIRECT dans la coop (coop.users / coop.mediateurs), au lieu
-- de la copie figée de main.personne.
--
-- Cause : depuis le décommissionnement de la branche personnes du coop-dag
-- (f372fe3, 2026-08-11 — ADR-002 coop : « pas de synchro continue de
-- main.personne »), plus personne n'écrit main.personne.contact->'coop'
-- (email, telephone) ni main.personne.is_visible : ce sont des copies gelées
-- au 11/08. api.carto (V154/V163) les servait encore dans `mediateurs` →
-- une médiatrice ayant retiré son téléphone de ProConnect (#1868) restait
-- exposée avec l'ancien numéro sur la cartographie nationale.
--
-- Mesure dev 2026-09-11 (3 766 personnes coop actives) : 4 téléphones
-- retirés côté coop encore servis, 107 téléphones ajoutés côté coop jamais
-- servis, 11 changés, 16 emails changés, 118 drapeaux de visibilité
-- divergents (dont 3 « masqué côté coop, visible côté main » et 100 jamais
-- posés), 51 médiateurs inscrits après le 11/08 absents de la carte
-- (is_mediateur jamais posé), 2 comptes coop supprimés encore servis.
--
-- Même doctrine que V144/V151/V153 : la coop est dans le cluster, on lit la
-- vérité au lieu de la répliquer. Sémantique reproduite :
--   - email     = coop.users.email, repli idposte (mail_pro, mail_perso) ;
--   - telephone = coop.users.phone normalisé E.164 par main.normaliser_telephone
--                 (port SQL de etl.transform.normalizer_utils.format_and_validate_phone,
--                 que le coop-dag appliquait), repli idposte ;
--   - visibilité = coop.mediateurs.is_visible (le drapeau que le médiateur
--                 pose lui-même), plus main.personne.is_visible ;
--   - médiateur  = présence dans coop.mediateurs (garantie par la vue
--                 main.personne_affectations_lieu), plus main.personne.is_mediateur ;
--   - un compte coop supprimé (coop.users.deleted) n'est plus servi.
-- Le reste de la vue (V163) est inchangé : CREATE OR REPLACE, colonnes
-- identiques, OID conservé (api.carto_departement/region, fonctions par nom).
--
-- Non traité ici (même cause, hors périmètre carte) : dataviz.personne et
-- dataviz.poste lisent encore contact->'coop' ; nom/prenom restent ceux de
-- main.personne.
--
-- Bloc défensif (doctrine V151) : sans schéma coop (CI/base neuve), la vue
-- reste telle quelle.

-- 1) Port SQL de format_and_validate_phone (etl/transform/normalizer_utils.py)
CREATE OR REPLACE FUNCTION main.normaliser_telephone(brut text)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $fn$
WITH e1 AS (SELECT regexp_replace(brut, '[ \-\.\(\)]', '', 'g') AS n),
     e2 AS (SELECT CASE WHEN n LIKE '00%' THEN '+' || substr(n, 3) ELSE n END AS n FROM e1),
     e3 AS (SELECT regexp_replace(n, '^\+33(?:0)?', '+33') AS n FROM e2),
     e4 AS (SELECT CASE WHEN n LIKE '0%' AND length(n) IN (9, 10) THEN '+33' || substr(n, 2) ELSE n END AS n FROM e3),
     pref AS (
         SELECT e4.n, p.prefixe
         FROM e4
         JOIN unnest(ARRAY['+33', '+590', '+594', '+262', '+596', '+269', '+687', '+689', '+508', '+681']) AS p(prefixe)
           ON e4.n LIKE p.prefixe || '%'
         ORDER BY length(p.prefixe) DESC
         LIMIT 1
     )
SELECT CASE WHEN substr(n, length(prefixe) + 1) ~ '^[0-9]{6,9}$' THEN n END
FROM pref
$fn$;

COMMENT ON FUNCTION main.normaliser_telephone(text) IS
    'Normalise un téléphone FR/DROM en E.164 (+33612345678) ou NULL si invalide. '
    'Port SQL strict de etl.transform.normalizer_utils.format_and_validate_phone (V164, SEPT #1868).';

-- 2) api.carto : médiateurs lus dans la coop
DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : api.carto inchangée (V164 ignorée).';
        RETURN;
    END IF;

    EXECUTE $v1$
    CREATE OR REPLACE VIEW api.carto AS
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
                    COALESCE(NULLIF(btrim(u.email), ''::text), (p.contact -> 'idposte'::text) ->> 'mail_pro'::text, (p.contact -> 'idposte'::text) ->> 'mail_perso'::text) AS email,
                    COALESCE(main.normaliser_telephone(u.phone), (p.contact -> 'idposte'::text) ->> 'telephone'::text) AS telephone,
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
                                  WHERE NOT flags.est_cn AND NOT flags.est_ac) labels
                          ORDER BY labels.ord) AS label
                   FROM main.personne_affectations_lieu pal
                     JOIN main.personne p ON p.id = pal.personne_id
                     JOIN coop.users u ON u.id = p.coop_id
                     JOIN coop.mediateurs m ON m.user_id = u.id
                     CROSS JOIN LATERAL ( SELECT p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL AS est_cn,
                            (EXISTS ( SELECT 1
                                   FROM main.personne_affectations_emploi pa_ac
                                  WHERE pa_ac.personne_id = p.id AND pa_ac.source::text = 'aidants-connect'::text AND pa_ac.est_active = true)) AS est_ac,
                            (EXISTS ( SELECT 1
                                   FROM main.personne_affectations_emploi pa_emp
                                  WHERE pa_emp.personne_id = p.id AND pa_emp.est_active = true AND pa_emp.source::text <> 'aidants-connect'::text)) AS a_emploi_actif_non_ac) flags
                  WHERE pal.est_active = true
                    AND u.deleted IS NULL
                    AND m.is_visible IS DISTINCT FROM false
                    AND (flags.est_ac OR flags.est_cn AND flags.a_emploi_actif_non_ac OR NOT flags.est_cn AND NOT flags.est_ac)) sub
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

    EXECUTE $c1$ COMMENT ON VIEW api.carto IS $t1$ Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion (fin de la photo mednum transitoire V154). `mediateurs` : coordonnées (coop.users), visibilité (coop.mediateurs.is_visible) et existence lues en direct dans la coop (V164, SEPT #1868). `pivot` non renseigné depuis #1711. $t1$ $c1$;
END
$mig$;

NOTIFY pgrst, 'reload schema';
