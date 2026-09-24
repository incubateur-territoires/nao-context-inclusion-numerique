-- ============================================================
-- V090 – Refonte phase 5.3 (suite) : api.carto_departement + api.carto_region
-- ============================================================
-- CONTEXTE :
-- Agrégats simples qui comptaient les structures visibles carto par dept/région.
-- Bascule sur main.lieu_inclusion (où vit désormais visible_pour_cartographie_nationale).
--
-- Comptages legacy 2026-05-22 : 15 339 lieux sommés sur 18 régions / 101 départements.
-- ============================================================

CREATE OR REPLACE VIEW api.carto_departement AS (
  SELECT coll_terr.departement_code AS code,
         coll_terr.departement_nom AS nom,
         COUNT(li.id) AS nombre_lieux
  FROM main.lieu_inclusion li
  JOIN main.adresse a ON a.id = li.adresse_id
  JOIN admin.coll_terr ON a.code_insee::text = coll_terr.code_insee::text
  WHERE li.visible_pour_cartographie_nationale
  GROUP BY coll_terr.departement_code, coll_terr.departement_nom
);

CREATE OR REPLACE VIEW api.carto_region AS (
  SELECT coll_terr.region_code AS code,
         coll_terr.region_nom AS nom,
         COUNT(li.id) AS nombre_lieux
  FROM main.lieu_inclusion li
  JOIN main.adresse a ON a.id = li.adresse_id
  JOIN admin.coll_terr ON a.code_insee::text = coll_terr.code_insee::text
  WHERE li.visible_pour_cartographie_nationale
  GROUP BY coll_terr.region_code, coll_terr.region_nom
);

GRANT SELECT ON TABLE api.carto_departement TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto_region TO postgrest_anct_carto;

NOTIFY pgrst, 'reload schema';
