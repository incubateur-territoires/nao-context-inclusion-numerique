DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'postgrest_anct_dev') THEN

      RAISE NOTICE 'Role "postgrest_anct_dev" already exists. Skipping.';
   ELSE
      CREATE ROLE postgrest_anct_dev NOLOGIN;
      COMMENT ON ROLE postgrest_anct_dev IS 'PostgREST ANCT role for dev tests';
   END IF;
END
$do$;


-- Allow app_api impersonate postgrest_anct_dev
GRANT postgrest_anct_dev TO app_api;


CREATE SCHEMA IF NOT EXISTS api;

COMMENT ON SCHEMA api IS E'ANCT Société Numérique - DataSpace API\n\nAPI REST de l''inclusion numérique portée par le programme Société Numérique de l''ANCT.\nDocumentation complémentaire sur la structure et le contenu des réponses :\nhttps://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts/-/wikis/API-entrepot\n\nAuthentification nécessaire par token.\nCréez un ticket sur https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts/-/issues/new';

GRANT USAGE ON SCHEMA api TO postgrest_anct_dev;

-- structures
CREATE VIEW api.structures AS (
    SELECT structure.siret, structure.rna, structure.nom, structure.code_activite_principale, structure.etat_administratif, structure.denomination_sirene,
      structure.categorie_juridique AS code_categorie_juridique, categories_juridiques.nom AS libelle_categorie_juridique,
      adresse.code_ban,adresse.numero_voie,adresse.nom_voie,adresse.repetition,adresse.code_postal,adresse.nom_commune,adresse.code_insee,concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie, adresse.code_postal, adresse.nom_commune) AS adresse,ST_X(adresse.geom) AS longitude, ST_Y(adresse.geom) AS latitude
    FROM main.structure
    LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
);

GRANT SELECT ON TABLE api.structures TO postgrest_anct_dev;


/*
/  Carto
*/

DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'postgrest_anct_carto') THEN

      RAISE NOTICE 'Role "postgrest_anct_carto" already exists. Skipping.';
   ELSE
      CREATE ROLE postgrest_anct_carto NOLOGIN;
      COMMENT ON ROLE postgrest_anct_carto IS 'PostgREST Carto ANCT role';
   END IF;
END
$do$;


-- Allow app_api impersonate postgrest_anct_carto
GRANT postgrest_anct_carto TO app_api;


GRANT USAGE ON SCHEMA auth, api TO postgrest_anct_carto;
GRANT EXECUTE ON FUNCTION auth.check_token TO postgrest_anct_carto;
GRANT SELECT ON TABLE auth.token TO postgrest_anct_carto;

-- Carto
-- Schema https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html
CREATE VIEW api.carto AS (
WITH courriels AS (
   SELECT structure_1.id,
      string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text]), VARIADIC ARRAY[key.key]), '|'::text) AS courriels_concat
      FROM main.structure structure_1,
      LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text])) key(key)
      GROUP BY structure_1.id
   )
 SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000'::character varying)::character varying(14) AS pivot,
    structure.nom,
    adresse.nom_commune AS commune,
    adresse.code_postal,
    adresse.code_insee,
    concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    NULL::text AS complement_adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    array_to_string(structure.typologies, '|'::text) AS typologie,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source,
    array_to_string(structure.itinerance, '|'::text) AS itinerance,
    structure.structure_parente,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    array_to_string(structure.services, '|'::text) AS services,
    array_to_string(structure.publics_specifiquement_adresses, '|'::text) AS publics_specifiquement_adresses,
    array_to_string(structure.prise_en_charge_specifique, '|'::text) AS prise_en_charge_specifique,
    array_to_string(structure.frais_a_charge, '|'::text) AS frais_a_charge,
    array_to_string(structure.dispositif_programmes_nationaux, '|'::text) AS dispositif_programmes_nationaux,
    array_to_string(structure.formations_labels, '|'::text) AS formations_labels,
    array_to_string(structure.autres_formations_labels, '|'::text) AS autres_formations_labels,
    array_to_string(structure.modalites_acces, '|'::text) AS modalites_acces,
    array_to_string(structure.modalites_accompagnement, '|'::text) AS modalites_accompagnement,
    structure.fiche_acces_libre,
    structure.prise_rdv
   FROM main.structure
   LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
   LEFT JOIN courriels ON courriels.id = structure.id
  WHERE structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale
);

COMMENT ON VIEW api.carto IS 'Cartographie nationale de l''inclusion numérique. Schéma : https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html';

COMMENT ON column api.carto.pivot IS 'Siret pour les entreprises, RNA pour les associations sans Siret.';
COMMENT ON column api.carto.latitude IS 'Latitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.longitude IS 'Longitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.horaires IS 'Horaires au format OSM. cf. https://wiki.openstreetmap.org/wiki/Key:opening_hours/specification#explain:time_domain';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
