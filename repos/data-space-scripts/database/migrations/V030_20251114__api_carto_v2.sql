DROP VIEW api.carto;

CREATE VIEW api.carto AS (
WITH courriels AS (
   SELECT structure_1.id,
      string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text]), VARIADIC ARRAY[key.key]), '|'::text) AS courriels_concat
      FROM main.structure structure_1,
      LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, VARIADIC ARRAY['emails'::text])) key(key)
      GROUP BY structure_1.id
   ), personnes AS (
   SELECT sub_table.structure_id,
      jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
      FROM ( SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique'::text, ','::text)
                        ELSE NULL::text[]
                  END, 'email', (personne.contact -> 'courriels'::text) ->> 'mail_pro'::text, 'telephone', personne.contact -> 'telephone'::text) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.suppression IS NULL AND personne_affectations.type::text = 'lieu_activite'::text AND (personne.is_active_ac IS FALSE OR personne.is_active_ac IS NULL OR personne.aidant_connect_id IS NULL) AND (personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL)
            UNION
            SELECT personne_affectations.structure_id,
               jsonb_build_object('prenom', personne.prenom, 'nom', personne.nom, 'label',
                  CASE
                        WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL THEN string_to_array('Conseiller Numerique,Aidant Connect'::text, ','::text)
                        ELSE string_to_array('Aidant Connect'::text, ','::text)
                  END) AS mediateurs
               FROM main.personne_affectations
               JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
            WHERE personne_affectations.suppression IS NULL AND personne_affectations.type::text = 'lieu_activite'::text AND (personne.is_active_ac IS TRUE OR personne.is_active_ac IS NOT NULL OR personne.aidant_connect_id IS NOT NULL)) sub_table
      GROUP BY sub_table.structure_id
   )
 SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000'::character varying)::character varying(14) AS pivot,
    structure.nom,
    jsonb_build_object(
      'numero_voie', adresse.numero_voie,
      'repetition', adresse.repetition,
      'nom_voie', adresse.nom_voie,
      'code_postal', adresse.code_postal,
      'commune', adresse.nom_commune,
      'code_insee', adresse.code_insee
    ) AS adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    structure.typologies AS typologie,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source AS source,
    structure.itinerance AS itinerance,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    structure.services AS services,
    structure.publics_specifiquement_adresses AS publics_specifiquement_adresses,
    structure.prise_en_charge_specifique AS prise_en_charge_specifique,
    structure.frais_a_charge AS frais_a_charge,
    structure.dispositif_programmes_nationaux AS dispositif_programmes_nationaux,
    structure.formations_labels AS formations_labels,
    structure.autres_formations_labels AS autres_formations_labels,
    structure.modalites_acces AS modalites_acces,
    structure.modalites_accompagnement AS modalites_accompagnement,
    structure.prise_rdv,
    personnes.mediateurs
   FROM main.structure
   LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
   LEFT JOIN courriels ON courriels.id = structure.id
   LEFT JOIN personnes ON personnes.structure_id = structure.id
  WHERE structure.structure_cartographie_nationale_id IS NOT NULL AND structure.visible_pour_cartographie_nationale
);

COMMENT ON VIEW api.carto IS 'Cartographie nationale de l''inclusion numérique.';

COMMENT ON column api.carto.id IS 'Identifiant de la cartographie nationale';
COMMENT ON column api.carto.pivot IS 'Identifiant de la structure (Siret pour les entreprises, RNA pour les associations sans Siret)';
COMMENT ON column api.carto.nom IS 'Nom de la structure';
COMMENT ON column api.carto.adresse IS 'Données relatives à l''adresse de la structure (numero_voie, repetition, nom_voie, code_postal, commune, code_insee)';
COMMENT ON column api.carto.latitude IS 'Latitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.longitude IS 'Longitude en WGS84 EPSG:4326.';
COMMENT ON column api.carto.typologie IS 'Typologie de la structure';
COMMENT ON column api.carto.telephone IS 'Numéro de téléphone du lieu.';
COMMENT ON column api.carto.courriels IS 'Courriels du lieu.';
COMMENT ON column api.carto.site_web IS 'Site Internet du lieu.';
COMMENT ON column api.carto.horaires IS 'Horaires au format OSM. cf. https://wiki.openstreetmap.org/wiki/Key:opening_hours/specification#explain:time_domain';
COMMENT ON column api.carto.presentation_resume IS 'Courte description du lieu';
COMMENT ON column api.carto.presentation_detail IS 'Description détaillée du lieu';
COMMENT ON column api.carto.source IS 'Source de la données ou du dernier modificateur.';
COMMENT ON column api.carto.itinerance IS 'Lieu d''inclusion numérique itinérant.';
COMMENT ON column api.carto.date_maj IS 'Date de la dernière mise à jour.';
COMMENT ON column api.carto.services IS 'Les types d’accompagnement proposés dans l’offre du lieu.';
COMMENT ON column api.carto.publics_specifiquement_adresses IS 'Types de public accueilli.';
COMMENT ON column api.carto.prise_en_charge_specifique IS 'Le lieu est en mesure d’accompagner et soutenir des publics ayant des besoins particuliers.';
COMMENT ON column api.carto.prise_en_charge_specifique IS 'Public ayant des besoins particuliers accompagné.';
COMMENT ON column api.carto.frais_a_charge IS 'Conditions financières d’accès.';
COMMENT ON column api.carto.dispositif_programmes_nationaux IS 'Appartenance à un dispositif ou à un programme national.';
COMMENT ON column api.carto.formations_labels IS 'Formations et labels obtenus par le lieu.';
COMMENT ON column api.carto.autres_formations_labels IS 'Autres formations ou labels.';
COMMENT ON column api.carto.modalites_acces IS 'Différentes étapes ou démarches à suivre pour se rendre au lieu d’inclusion numérique et bénéficier de ses services.';
COMMENT ON column api.carto.modalites_accompagnement IS 'Types d’accompagnement proposés';
COMMENT ON column api.carto.prise_rdv IS 'Lien vers le site de prise de rendez-vous.';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
