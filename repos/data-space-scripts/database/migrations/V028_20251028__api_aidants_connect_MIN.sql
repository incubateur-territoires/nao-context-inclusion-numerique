DO
$do$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'postgrest_anct_incub') THEN

      RAISE NOTICE 'Role "postgrest_anct_incub" already exists. Skipping.';
   ELSE
      CREATE ROLE postgrest_anct_incub NOLOGIN;
      COMMENT ON ROLE postgrest_anct_incub IS 'PostgREST Incubateur ANCT role';
   END IF;
END
$do$;

-- Ajout des droits sur l'endpoint `carto`
GRANT SELECT ON TABLE api.carto TO postgrest_anct_incub;

-- Aidants Connect (API)
-- Expose : aidant_connect_id, id (personne), nb_accompagnements,
--          structure_employeuse au format JSON (id, nom, adresse, code_insee, commune, departement)
CREATE VIEW api.aidants_connect AS (
WITH employeurs AS (
  SELECT DISTINCT ON (pa.personne_id)
    pa.personne_id,
    s.id           AS structure_id,
    s.nom          AS nom,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie) AS adresse,
    a.code_insee   AS code_insee,
    a.nom_commune  AS commune,
    a.departement  AS code_departement
  FROM main.personne_affectations pa
  JOIN main.structure s ON s.id = pa.structure_id
  LEFT JOIN main.adresse a ON a.id = s.adresse_id
  WHERE pa.structure_id IS NOT NULL
    AND pa.suppression IS NULL
  ORDER BY
    pa.personne_id,
    CASE WHEN pa.type IN ('structure_emploi') THEN 0 ELSE 1 END,
    coalesce(pa.updated_at, pa.created_at) DESC,
    pa.id DESC
)
SELECT
  p.aidant_connect_id,
  p.id AS id,
  coalesce(p.nb_accompagnements_ac, 0) AS nb_accompagnements,
  e.code_insee AS code_insee,
  jsonb_strip_nulls(
    jsonb_build_object(
      'id',         e.structure_id,
      'nom',        e.nom,
      'adresse',    e.adresse,
      'code_insee', e.code_insee,
      'commune',    e.commune,
      'departement',e.code_departement
    )
  ) AS structure_employeuse
FROM main.personne p
LEFT JOIN employeurs e ON e.personne_id = p.id
WHERE p.aidant_connect_id IS NOT NULL
);

COMMENT ON VIEW api.aidants_connect IS
  'Aidants Connect : personnes (aidant_connect_id, id, nb_accompagnements) + structure employeuse en JSON (id, nom, adresse, code_insee, commune, departement).';
-- Ajouter une description aux colonnes de la vue
COMMENT ON COLUMN api.aidants_connect.aidant_connect_id IS
  'Identifiant unique de l''aidant dans le système Aidants Connect.';
COMMENT ON COLUMN api.aidants_connect.id IS
    'Identifiant unique de la personne dans DataSpace.';
COMMENT ON COLUMN api.aidants_connect.nb_accompagnements IS
    'Nombre d''accompagnements / Démarches administratives réalisés par l''aidant via Aidants Connect.';
COMMENT ON COLUMN api.aidants_connect.structure_employeuse IS
    'Informations sur la structure employeuse de l''aidant';
COMMENT ON COLUMN api.aidants_connect.code_insee IS
    'Code INSEE de la commune de la structure employeuse de l''aidant.';

-- Accorder les permissions de lecture sur la vue aux rôles API concernés
GRANT SELECT ON TABLE api.aidants_connect TO postgrest_anct_incub;

-- API MIN -> Feuille de route ANCT Incub (agrégé, counts only)
-- Basé sur :
-- (1) total = COUNT(fdr.id)
-- (2) répartition par département, triée par nb_feuilles DESC

CREATE OR REPLACE VIEW api.feuille_de_route AS
WITH dept_names AS (
  SELECT
    ct.departement_code,
    MIN(ct.departement_nom) AS nom_departement
  FROM admin.coll_terr ct
  WHERE ct.departement_code IS NOT NULL
  GROUP BY ct.departement_code
),
deps AS (
  SELECT
    fdr.gouvernance_departement_code AS code_departement,
    dn.nom_departement,
    COUNT(DISTINCT fdr.id)::int AS nb_feuilles
  FROM min.feuille_de_route fdr
  LEFT JOIN dept_names dn
    ON dn.departement_code = fdr.gouvernance_departement_code
  WHERE dn.nom_departement IS NOT NULL   -- ignorer les codes sans nom
  GROUP BY fdr.gouvernance_departement_code, dn.nom_departement
),
total_france AS (
  SELECT COUNT(DISTINCT id)::int AS total
  FROM min.feuille_de_route
)
SELECT
  (SELECT total FROM total_france) AS total,
  COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code_departement', d.code_departement,
        'nom_departement',  d.nom_departement,
        'nb_feuilles',      d.nb_feuilles
      )
      ORDER BY d.nb_feuilles DESC, d.code_departement
    ),
    '[]'::jsonb
  ) AS departements
FROM deps d;

COMMENT ON VIEW api.feuille_de_route IS
  'Feuilles de route : total France et répartition par département (code, nom, nb_feuilles), filtré sur les départements.';

COMMENT ON COLUMN api.feuille_de_route.total IS
  'Nombre total de feuilles de route en France.';

COMMENT ON COLUMN api.feuille_de_route.departements IS
  'Tableau JSON des départements avec code, nom et nombre de feuilles.';

GRANT SELECT ON TABLE api.feuille_de_route TO postgrest_anct_incub;

NOTIFY pgrst, 'reload schema';
