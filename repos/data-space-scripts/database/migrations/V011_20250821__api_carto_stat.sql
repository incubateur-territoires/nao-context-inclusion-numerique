CREATE VIEW api.carto_region AS (
 SELECT region_code AS code, region_nom AS nom,
   COUNT(structure.id) AS nombre_lieux
   FROM main.structure
   INNER JOIN main.adresse ON adresse.id = structure.adresse_id
   INNER JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
  WHERE structure.visible_pour_cartographie_nationale
  GROUP BY region_code, region_nom
);

COMMENT ON VIEW api.carto_region IS 'Nombre de lieux d''inclusion numérique par région.';

GRANT SELECT ON TABLE api.carto_region TO postgrest_anct_carto;


CREATE VIEW api.carto_departement AS (
 SELECT departement_code AS code, departement_nom AS nom,
   COUNT(structure.id) AS nombre_lieux
   FROM main.structure
   INNER JOIN main.adresse ON adresse.id = structure.adresse_id
   INNER JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
  WHERE structure.visible_pour_cartographie_nationale
  GROUP BY departement_code, departement_nom
);

COMMENT ON VIEW api.carto_departement IS 'Nombre de lieux d''inclusion numérique par département.';

GRANT SELECT ON TABLE api.carto_departement TO postgrest_anct_carto;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
