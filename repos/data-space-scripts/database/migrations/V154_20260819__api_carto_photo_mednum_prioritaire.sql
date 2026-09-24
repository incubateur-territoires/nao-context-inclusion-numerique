-- V154 : sur l'export public (api.carto + opendata), les fiches des LIEUX
-- COOP sont servies depuis la PHOTO MEDNUM (silver du run courant) ; toutes
-- les autres fiches restent servies depuis la vue/le registre. SEPT #1724.
--
-- Pourquoi : la bascule V153 a fait servir la vérité coop partout — y
-- compris sur l'export public, dont les consommateurs externes (carte,
-- data.gouv, partenaires data-inclusion) recevaient jusqu'ici la photo du
-- fichier national. Posture TRANSITOIRE actée le 2026-08-19 : tant que la
-- décision métier (canal des lieux communs — requête de modification vs
-- écriture arbitrée) n'est pas prise, l'export public ne change pas de
-- nature ; MIN / dataviz / consommateurs internes continuent de lire la
-- vérité coop via main.lieu_inclusion. C'est une « divergence assumée »
-- temporaire et documentée (analyse_bascule_vue_union_v153.md §6).
--
-- Mécanique : LEFT JOIN staging.carto__structures (le silver ne contient
-- que le run courant, TRUNCATE+INSERT transactionnel) ; chaque champ métier
-- servi depuis le silver quand le record y est ET que la ligne est un lieu
-- coop (normalisation identique à l'ancien _CARTO_COMMON_SET du carto-dag),
-- sinon depuis la vue. La priorité silver est LIMITÉE aux lignes coop : pour
-- les lieux externes, le registre EST déjà la photo mednum matérialisée
-- chaque nuit (fraîcheur arbitrée) — le servir préserve, comme avant le
-- chantier, les éditions locales (MIN) gardées par la garde de fraîcheur.
-- Restent
-- issus de l'entrepôt dans tous les cas : adresse/lat-long (main.adresse),
-- visibilité (cycle de vie ET drapeau coop — fix des 20 conservé),
-- médiateurs (affectations coop en direct), complement_adresse.
--
-- Aucune de ces 3 vues n'a de dépendant → DROP/CREATE simple.

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
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.nom::character varying ELSE li.nom END AS nom,
    jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'code_postal', a.code_postal, 'commune', a.nom_commune, 'code_insee', a.code_insee) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.typologie, '|')::main.typologie[] ELSE li.typologies END AS typologie,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.telephone, '') ELSE jsonb_extract_path_text(li.contact, VARIADIC ARRAY['telephone'::text]) END AS telephone,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.courriels, '') ELSE courriels.courriels_concat END AS courriels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.site_web, '') ELSE jsonb_extract_path_text(li.contact, VARIADIC ARRAY['site_web'::text]) END AS site_web,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.horaires::character varying ELSE li.horaires END AS horaires,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_resume ELSE li.presentation_resume END AS presentation_resume,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_detail ELSE li.presentation_detail END AS presentation_detail,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.source::character varying ELSE li.source END AS source,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.itinerance, '|')::main.itinerance[] ELSE li.itinerance END AS itinerance,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.date_maj::timestamp ELSE COALESCE(li.updated_at, li.created_at) END AS date_maj,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.services, '|')::main.service[] ELSE li.services END AS services,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.publics_specifiquement_adresses, '|')::main.public_specifiquement_adresse[] ELSE li.publics_specifiquement_adresses END AS publics_specifiquement_adresses,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.prise_en_charge_specifique, '|')::main.prise_en_charge_specifique[] ELSE li.prise_en_charge_specifique END AS prise_en_charge_specifique,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.frais_a_charge, '|')::main.frais_a_charge[] ELSE li.frais_a_charge END AS frais_a_charge,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.dispositif_programmes_nationaux, '|')::main.dispositif_programme_national[] ELSE li.dispositif_programmes_nationaux END AS dispositif_programmes_nationaux,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.formations_labels, '|')::main.formation_label[] ELSE li.formations_labels END AS formations_labels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.autres_formations_labels, '|') ELSE li.autres_formations_labels END AS autres_formations_labels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.modalites_acces, '|')::main.modalite_acces[] ELSE li.modalites_acces END AS modalites_acces,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.modalites_accompagnement, '|')::main.modalite_accompagnement[] ELSE li.modalites_accompagnement END AS modalites_accompagnement,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.prise_rdv::character varying ELSE li.prise_rdv END AS prise_rdv,
    personnes.mediateurs
FROM main.lieu_inclusion li
LEFT JOIN staging.carto__structures c ON c.id = li.structure_cartographie_nationale_id
LEFT JOIN main.adresse a ON a.id = li.adresse_id
LEFT JOIN courriels ON courriels.id = li.id
LEFT JOIN personnes ON personnes.lieu_id = li.id
WHERE li.structure_cartographie_nationale_id IS NOT NULL
  AND li.visible_pour_cartographie_nationale = true;

COMMENT ON VIEW api.carto IS
    'Vue cartographie publique. PHOTO MEDNUM prioritaire (V154, transitoire '
    'SEPT #1724) : champs métier servis depuis staging.carto__structures '
    'quand le record est au fichier national du run courant, sinon depuis '
    'main.lieu_inclusion (vérité coop/registre). Adresse, visibilité '
    '(cycle de vie ET drapeau coop) et médiateurs restent issus de '
    'l''entrepôt. `pivot` non renseigné depuis #1711.';

CREATE VIEW opendata.lieux_mednum AS
SELECT li.structure_cartographie_nationale_id AS id,
    '00000000000000'::character varying(14) AS pivot,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.nom::character varying ELSE li.nom END AS nom,
    a.nom_commune AS commune,
    a.code_postal,
    a.code_insee,
    concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
    li.complement_adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.typologie ELSE array_to_string(li.typologies, '|'::text) END AS typologie,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.telephone, '') ELSE li.contact ->> 'telephone'::text END AS telephone,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.courriels, '')
         ELSE (SELECT string_agg(v.value, '|'::text)
               FROM jsonb_each_text(li.contact -> 'courriels'::text) v(key, value)
               WHERE v.key = 'email'::text) END AS courriels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN NULLIF(c.site_web, '') ELSE li.contact ->> 'site_web'::text END AS site_web,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.horaires::character varying ELSE li.horaires END AS horaires,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_resume ELSE li.presentation_resume END AS presentation_resume,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_detail ELSE li.presentation_detail END AS presentation_detail,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.source::character varying ELSE li.source END AS source,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.itinerance ELSE array_to_string(li.itinerance, '|'::text) END AS itinerance,
    NULL::text AS structure_parente,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.date_maj::timestamp ELSE COALESCE(li.updated_at, li.created_at) END AS date_maj,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.services ELSE array_to_string(li.services, '|'::text) END AS services,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.publics_specifiquement_adresses ELSE array_to_string(li.publics_specifiquement_adresses, '|'::text) END AS publics_specifiquement_adresses,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.prise_en_charge_specifique ELSE array_to_string(li.prise_en_charge_specifique, '|'::text) END AS prise_en_charge_specifique,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.frais_a_charge ELSE array_to_string(li.frais_a_charge, '|'::text) END AS frais_a_charge,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.dispositif_programmes_nationaux ELSE array_to_string(li.dispositif_programmes_nationaux, '|'::text) END AS dispositif_programmes_nationaux,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.formations_labels ELSE array_to_string(li.formations_labels, '|'::text) END AS formations_labels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.autres_formations_labels ELSE array_to_string(li.autres_formations_labels, '|'::text) END AS autres_formations_labels,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.modalites_acces ELSE array_to_string(li.modalites_acces, '|'::text) END AS modalites_acces,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.modalites_accompagnement ELSE array_to_string(li.modalites_accompagnement, '|'::text) END AS modalites_accompagnement,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.fiche_acces_libre::character varying ELSE li.fiche_acces_libre END AS fiche_acces_libre,
    CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.prise_rdv::character varying ELSE li.prise_rdv END AS prise_rdv
FROM main.lieu_inclusion li
LEFT JOIN staging.carto__structures c ON c.id = li.structure_cartographie_nationale_id
LEFT JOIN main.adresse a ON li.adresse_id = a.id
WHERE li.deleted_at IS NULL
  AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale);

COMMENT ON VIEW opendata.lieux_mednum IS
    'Export opendata (data.gouv). PHOTO MEDNUM prioritaire (V154, transitoire '
    'SEPT #1724) : mêmes règles qu''api.carto.';

CREATE VIEW opendata.lieux_geojson AS
WITH features AS (
    SELECT a.geom,
           li.structure_cartographie_nationale_id,
           NULL::character varying AS siret,
           NULL::character varying AS rna,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.nom::character varying ELSE li.nom END AS nom,
           jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'complement_adresse', li.complement_adresse, 'code_postal', a.code_postal, 'nom_commune', a.nom_commune, 'code_insee', a.code_insee, 'clef_interop', a.clef_interop, 'code_ban', a.code_ban) AS adresse,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.typologie, '|')::main.typologie[] ELSE li.typologies END AS typologies,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN
               jsonb_strip_nulls(jsonb_build_object(
                   'telephone', to_jsonb(NULLIF(c.telephone, '')),
                   'site_web', to_jsonb(NULLIF(c.site_web, '')),
                   'courriels', CASE WHEN NULLIF(c.courriels, '') IS NOT NULL
                                     THEN jsonb_build_object('email', c.courriels) END))
           ELSE
               jsonb_strip_nulls(jsonb_build_object(
                   'telephone', li.contact -> 'telephone'::text,
                   'site_web', li.contact -> 'site_web'::text,
                   'courriels', (SELECT jsonb_object_agg(v.key, v.value)
                                 FROM jsonb_each(li.contact -> 'courriels'::text) v(key, value)
                                 WHERE v.key = 'email'::text)))
           END AS contacts,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.horaires::character varying ELSE li.horaires END AS horaires,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_resume ELSE li.presentation_resume END AS presentation_resume,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.presentation_detail ELSE li.presentation_detail END AS presentation_detail,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.source::character varying ELSE li.source END AS source,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.itinerance, '|')::main.itinerance[] ELSE li.itinerance END AS itinerance,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.services, '|')::main.service[] ELSE li.services END AS services,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.publics_specifiquement_adresses, '|')::main.public_specifiquement_adresse[] ELSE li.publics_specifiquement_adresses END AS publics_specifiquement_adresses,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.prise_en_charge_specifique, '|')::main.prise_en_charge_specifique[] ELSE li.prise_en_charge_specifique END AS prise_en_charge_specifique,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.frais_a_charge, '|')::main.frais_a_charge[] ELSE li.frais_a_charge END AS frais_a_charge,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.dispositif_programmes_nationaux, '|')::main.dispositif_programme_national[] ELSE li.dispositif_programmes_nationaux END AS dispositif_programmes_nationaux,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.formations_labels, '|')::main.formation_label[] ELSE li.formations_labels END AS formations_labels,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.autres_formations_labels, '|') ELSE li.autres_formations_labels END AS autres_formations_labels,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.modalites_acces, '|')::main.modalite_acces[] ELSE li.modalites_acces END AS modalites_acces,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN string_to_array(c.modalites_accompagnement, '|')::main.modalite_accompagnement[] ELSE li.modalites_accompagnement END AS modalites_accompagnement,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.fiche_acces_libre::character varying ELSE li.fiche_acces_libre END AS fiche_acces_libre,
           CASE WHEN c.id IS NOT NULL AND li.structure_coop_id IS NOT NULL THEN c.prise_rdv::character varying ELSE li.prise_rdv END AS prise_rdv
    FROM main.lieu_inclusion li
    LEFT JOIN staging.carto__structures c ON c.id = li.structure_cartographie_nationale_id
    LEFT JOIN main.adresse a ON li.adresse_id = a.id
    WHERE li.deleted_at IS NULL
      AND (li.structure_cartographie_nationale_id IS NOT NULL OR li.visible_pour_cartographie_nationale)
)
SELECT jsonb_build_object('type', 'FeatureCollection', 'features', json_agg(st_asgeojson(features.*)::jsonb)) AS jsonb_build_object
FROM features;

COMMENT ON VIEW opendata.lieux_geojson IS
    'Export GeoJSON opendata. PHOTO MEDNUM prioritaire (V154, transitoire '
    'SEPT #1724) : mêmes règles qu''api.carto.';

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
