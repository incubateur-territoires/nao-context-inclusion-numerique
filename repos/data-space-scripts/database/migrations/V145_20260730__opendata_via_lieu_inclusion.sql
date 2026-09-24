-- ============================================================
-- V145 – opendata.* : bascule sur main.lieu_inclusion (refonte N11)
-- ============================================================
-- CONTEXTE :
-- Les vues opendata.lieux_mednum et opendata.lieux_geojson (V057) lisaient
-- main.structure, que plus aucun DAG n'alimente depuis la refonte
-- structure_administrative / lieu_inclusion : le DAG opendata-publication
-- publiait donc sur data.gouv.fr des données figées depuis la bascule.
-- Elles lisent désormais main.lieu_inclusion (mêmes colonnes, mêmes formats).
--
-- Différences de comportement assumées :
--   - `pivot` (mednum) et `siret`/`rna` (geojson) : plus de SIRET porté par les
--     lieux depuis #1711 (lien lieu ↔ structure_administrative supprimé, cf
--     V123 qui a fait le même choix pour api.carto). pivot = '00000000000000',
--     siret/rna = NULL. Types conservés.
--   - `complement_adresse` : renseigné (main.lieu_inclusion.complement_adresse,
--     V121) au lieu de NULL.
--   - `courriels` : seule la clé `email` de l'objet contact->'courriels' est
--     lue (comme en legacy V057). Les autres clés sont exclues :
--     `mail_gestionnaire` / `referent_hierarchique` / `mail_N` portent des
--     emails NOMINATIFS internes (référents V047), `email_N` écarté aussi
--     (décision 2026-07-30).
--   - `contacts` (geojson) : JSONB reconstruit (telephone / site_web /
--     courriels filtré sur `email`) au lieu du JSONB brut, pour la même raison.
--
-- DROP + CREATE (et non CREATE OR REPLACE) : le type de `pivot` change
-- (varchar ← coalesce de colonnes legacy). Grants repositionnés.

DROP VIEW IF EXISTS opendata.lieux_mednum;
CREATE VIEW opendata.lieux_mednum AS (
    SELECT
        li.structure_cartographie_nationale_id AS id,
        '00000000000000'::character varying(14) AS pivot,
        li.nom AS nom,
        a.nom_commune AS commune,
        a.code_postal AS code_postal,
        a.code_insee AS code_insee,
        concat_ws(' '::text, a.numero_voie, a.repetition, a.nom_voie) AS adresse,
        li.complement_adresse AS complement_adresse,
        ST_Y(a.geom) AS latitude,
        ST_X(a.geom) AS longitude,
        array_to_string(li.typologies, '|'::text) AS typologie,
        li.contact ->> 'telephone' AS telephone,
        (SELECT string_agg(v.value, '|')
         FROM jsonb_each_text(li.contact -> 'courriels') v
         WHERE v.key = 'email') AS courriels,
        li.contact ->> 'site_web' AS site_web,
        li.horaires AS horaires,
        li.presentation_resume AS presentation_resume,
        li.presentation_detail AS presentation_detail,
        li.source AS source,
        array_to_string(li.itinerance, '|'::text) AS itinerance,
        NULL AS structure_parente,
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
        li.fiche_acces_libre AS fiche_acces_libre,
        li.prise_rdv AS prise_rdv
    FROM main.lieu_inclusion li
    LEFT JOIN main.adresse a ON li.adresse_id = a.id
    -- deleted_at : soft delete MIN (V138) postérieur à l'écriture de cette vue —
    -- un lieu supprimé ne doit pas être publié en opendata.
    WHERE li.deleted_at IS NULL
      AND (li.structure_cartographie_nationale_id IS NOT NULL
           OR li.visible_pour_cartographie_nationale)
);

COMMENT ON VIEW opendata.lieux_mednum IS
  'Vue des lieux médiation numérique au format de la MédNum. Source : '
  'main.lieu_inclusion (V145). pivot non renseigné depuis #1711 (pas de SIRET '
  'porté par les lieux).';

GRANT SELECT ON TABLE opendata.lieux_mednum TO app_python;

DROP VIEW IF EXISTS opendata.lieux_geojson;
CREATE VIEW opendata.lieux_geojson AS (
    WITH features AS (
        SELECT a.geom,
        li.structure_cartographie_nationale_id,
        NULL::character varying AS siret,
        NULL::character varying AS rna,
        li.nom,
        jsonb_build_object(
            'numero_voie', a.numero_voie,
            'repetition', a.repetition,
            'nom_voie', a.nom_voie,
            'complement_adresse', li.complement_adresse,
            'code_postal', a.code_postal,
            'nom_commune', a.nom_commune,
            'code_insee', a.code_insee,
            'clef_interop', a.clef_interop,
            'code_ban', a.code_ban
        ) AS adresse,
        li.typologies,
        jsonb_strip_nulls(jsonb_build_object(
            'telephone', li.contact -> 'telephone',
            'site_web', li.contact -> 'site_web',
            'courriels', (SELECT jsonb_object_agg(v.key, v.value)
                          FROM jsonb_each(li.contact -> 'courriels') v
                          WHERE v.key = 'email')
        )) AS contacts,
        li.horaires,
        li.presentation_resume, li.presentation_detail, li.source,
        li.itinerance, li.services, li.publics_specifiquement_adresses,
        li.prise_en_charge_specifique, li.frais_a_charge,
        li.dispositif_programmes_nationaux, li.formations_labels,
        li.autres_formations_labels, li.modalites_acces,
        li.modalites_accompagnement, li.fiche_acces_libre, li.prise_rdv
        FROM main.lieu_inclusion li
        LEFT JOIN main.adresse a ON li.adresse_id = a.id
        WHERE li.deleted_at IS NULL
          AND (li.structure_cartographie_nationale_id IS NOT NULL
               OR li.visible_pour_cartographie_nationale)
    )
    SELECT jsonb_build_object(
        'type', 'FeatureCollection',
        'features', json_agg(ST_AsGeoJSON(features.*)::jsonb)
        )
    FROM features
);

COMMENT ON VIEW opendata.lieux_geojson IS
  'Vue des lieux médiation numérique pour publication au format GeoJSON. '
  'Source : main.lieu_inclusion (V145). siret/rna NULL depuis #1711.';

GRANT SELECT ON TABLE opendata.lieux_geojson TO app_python;
