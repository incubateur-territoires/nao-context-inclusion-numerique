/*
  Vue matérialisée : dataviz.structure_similarities

  Objectif :
    Détecter les structures en doublon en comparant les noms normalisés (unaccent, lower)
    de toutes les structures partageant le même SIRET et la même adresse.

  Règle de fusion :
    - La priorité est donnée aux structures ayant un `structure_tp_id` (type TP),
    - puis à celles ayant un `structure_coop_id` si l’autre n’en a pas et que l’autre est `is_ac`.

  Voir la documentation complète ici :
    https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts/-/wikis/ds-wiki/similarities/structure
*/

DROP MATERIALIZED VIEW IF EXISTS dataviz.structure_similarities;


CREATE MATERIALIZED VIEW dataviz.structure_similarities AS
-- Description de la vue matérialisée dans le catalogue :
WITH base AS (
  SELECT id, nom, unaccent(lower(nom)) AS nom_norm, siret, adresse_id,
    structure_tp_id, structure_coop_id, structure_ac_id,
    (structure_tp_id IS NOT NULL) AS has_tp,
    (structure_coop_id IS NOT NULL) AS has_coop,
    (structure_ac_id IS NOT NULL) AS is_ac
  FROM main.structure
  WHERE siret IS NOT NULL AND siret <> '' AND adresse_id IS NOT NULL
),
pairs AS (
  SELECT a.id AS id_a, b.id AS id_b, a.nom AS nom_a, b.nom AS nom_b,
    a.has_tp AS a_has_tp, a.has_coop AS a_has_coop, a.is_ac AS a_is_ac,
    b.has_tp AS b_has_tp, b.has_coop AS b_has_coop, b.is_ac AS b_is_ac,
    similarity(a.nom_norm, b.nom_norm) AS similarity_score
  FROM base a
  JOIN base b ON a.id < b.id AND a.siret = b.siret AND a.adresse_id = b.adresse_id
),
ranked AS (
  SELECT *,
    CASE
      WHEN a_has_tp AND NOT b_has_tp THEN id_a
      WHEN b_has_tp AND NOT a_has_tp THEN id_b
      WHEN a_has_coop AND NOT b_has_coop AND b_is_ac THEN id_a
      WHEN b_has_coop AND NOT a_has_coop AND a_is_ac THEN id_b
      ELSE NULL
    END AS winner_id,
    CASE
      WHEN a_has_tp AND NOT b_has_tp THEN id_b
      WHEN b_has_tp AND NOT a_has_tp THEN id_a
      WHEN a_has_coop AND NOT b_has_coop AND b_is_ac THEN id_b
      WHEN b_has_coop AND NOT a_has_coop AND a_is_ac THEN id_a
      ELSE NULL
    END AS loser_id
  FROM pairs
)
SELECT winner_id, loser_id,
  CASE WHEN winner_id = id_a THEN nom_a ELSE nom_b END AS winner_nom,
  CASE WHEN loser_id = id_a THEN nom_a ELSE nom_b END AS loser_nom,
  similarity_score,
  to_jsonb(jsonb_strip_nulls(to_jsonb(winner.*))) AS winner_structure,
  to_jsonb(jsonb_strip_nulls(to_jsonb(loser.*))) AS loser_structure
FROM ranked
JOIN main.structure winner ON winner.id = winner_id
JOIN main.structure loser ON loser.id = loser_id
WHERE winner_id IS NOT NULL AND loser_id IS NOT NULL AND similarity_score > 0
ORDER BY similarity_score DESC;

COMMENT ON MATERIALIZED VIEW dataviz.structure_similarities IS
'Détecte les structures en doublon en comparant les noms (unaccent, lower) pour les structures partageant le même SIRET et adresse. Priorité aux structures avec structure_tp_id, puis structure_coop_id vs is_ac. Voir : https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts/-/wikis/ds-wiki/similarities/structure';
