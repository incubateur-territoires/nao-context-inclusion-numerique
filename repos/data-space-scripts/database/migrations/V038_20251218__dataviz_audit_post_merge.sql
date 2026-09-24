-- Expose audit merge logs to Metabase via dataviz views
-- Source tables are in schema `audit` while Metabase reads schema `dataviz`.

-- ==========================
-- 1) Personne merge log view
-- ==========================
CREATE OR REPLACE VIEW dataviz.personne_post_merge_log AS
SELECT
  l.id,
  l.merged_at,
  l.status,
  l.dag_id,
  l.run_id,
  l.task_id,
  l.winner_id,
  l.loser_id,
  l.similarity_threshold,

  COALESCE(l.winner_after  ->> 'nom',    l.winner_before ->> 'nom')    AS winner_nom,
  COALESCE(l.winner_after  ->> 'prenom', l.winner_before ->> 'prenom') AS winner_prenom,
  l.loser_before ->> 'nom'    AS loser_nom,
  l.loser_before ->> 'prenom' AS loser_prenom,

  COALESCE(l.winner_after  ->> 'aidant_connect_id',       l.winner_before ->> 'aidant_connect_id')       AS winner_aidant_connect_id,
  COALESCE(l.winner_after  ->> 'cn_pg_id',                l.winner_before ->> 'cn_pg_id')                AS winner_cn_pg_id,
  COALESCE(l.winner_after  ->> 'conseiller_numerique_id', l.winner_before ->> 'conseiller_numerique_id') AS winner_conseiller_numerique_id,

  l.loser_before ->> 'aidant_connect_id'       AS loser_aidant_connect_id,
  l.loser_before ->> 'cn_pg_id'                AS loser_cn_pg_id,
  l.loser_before ->> 'conseiller_numerique_id' AS loser_conseiller_numerique_id,

  l.moved_identifiers -> 'loser'       ->> 'coop_id' AS loser_coop_id,
  l.moved_identifiers -> 'winner_after'->> 'coop_id' AS winner_coop_id,

  l.error_message,

  l.winner_before,
  l.loser_before,
  l.winner_after,
  l.moved_identifiers
FROM audit.personne_merge_log l;


-- ============================
-- 2) Structure merge log view
-- ============================
CREATE OR REPLACE VIEW dataviz.structure_post_merge_log AS
SELECT
  l.id,
  l.merged_at,
  l.status,
  l.dag_id,
  l.run_id,
  l.task_id,
  l.winner_id,
  l.loser_id,
  l.similarity_threshold,

  COALESCE(l.winner_after  ->> 'nom',   l.winner_before ->> 'nom')   AS winner_nom,
  l.loser_before ->> 'nom' AS loser_nom,

  COALESCE(l.winner_after  ->> 'siret', l.winner_before ->> 'siret') AS winner_siret,
  l.loser_before ->> 'siret' AS loser_siret,

  COALESCE(l.winner_after  ->> 'source', l.winner_before ->> 'source') AS winner_source,
  l.loser_before ->> 'source' AS loser_source,

  l.moved_identifiers -> 'loser'       ->> 'structure_coop_id'                    AS loser_structure_coop_id,
  l.moved_identifiers -> 'loser'       ->> 'structure_ac_id'                      AS loser_structure_ac_id,
  l.moved_identifiers -> 'loser'       ->> 'structure_cartographie_nationale_id'  AS loser_structure_cartographie_nationale_id,

  l.moved_identifiers -> 'winner_after'->> 'structure_coop_id'                    AS winner_structure_coop_id,
  l.moved_identifiers -> 'winner_after'->> 'structure_ac_id'                      AS winner_structure_ac_id,
  l.moved_identifiers -> 'winner_after'->> 'structure_cartographie_nationale_id'  AS winner_structure_cartographie_nationale_id,

  l.error_message,

  l.winner_before,
  l.loser_before,
  l.winner_after,
  l.moved_identifiers
FROM audit.structure_merge_log l;
