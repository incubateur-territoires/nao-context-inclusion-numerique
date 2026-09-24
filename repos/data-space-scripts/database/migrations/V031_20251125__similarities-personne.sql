ALTER TABLE main.coordination_mediation
DROP CONSTRAINT coordination_mediation_coordinateur_coop_id_fkey,
DROP CONSTRAINT coordination_mediation_mediateur_coop_id_fkey;

DROP MATERIALIZED VIEW IF EXISTS dataviz.personne_similarities;

-- Description:
-- Vue matérialisée listant les paires potentielles de personnes à fusionner
-- entre Aidants Connect et Conseiller Numérique.

CREATE MATERIALIZED VIEW dataviz.personne_similarities AS
WITH fusionnes AS (
    SELECT id
    FROM main.personne
    WHERE cn_pg_id IS NOT NULL AND aidant_connect_id IS NOT NULL
),

ac AS (
    SELECT
        p.id AS id_ac,
        unaccent(lower(trim(p.nom)))     AS nom_n,
        unaccent(lower(trim(p.prenom)))  AS prenom_n,
        a.code_insee,
        p.updated_at AS updated_ac,
        p.created_at AS created_ac
    FROM main.personne p
    JOIN main.personne_affectations pa ON pa.personne_id = p.id
    JOIN main.structure s              ON s.id = pa.structure_id
    JOIN main.adresse a                ON a.id = s.adresse_id
    WHERE p.aidant_connect_id IS NOT NULL
      AND pa.suppression IS NULL
      AND pa.type = 'structure_emploi'
      AND p.nom IS NOT NULL
      AND p.prenom IS NOT NULL
      AND p.id NOT IN (SELECT id FROM fusionnes)
),

cn AS (
    SELECT
        p.id AS id_cn,
        unaccent(lower(trim(p.nom)))     AS nom_n,
        unaccent(lower(trim(p.prenom)))  AS prenom_n,
        a.code_insee,
        p.updated_at AS updated_cn,
        p.created_at AS created_cn
    FROM main.personne p
    JOIN main.personne_affectations pa ON pa.personne_id = p.id
    JOIN main.structure s              ON s.id = pa.structure_id
    JOIN main.adresse a                ON a.id = s.adresse_id
    WHERE p.cn_pg_id IS NOT NULL
      AND pa.suppression IS NULL
      AND pa.type = 'structure_emploi'
      AND p.nom IS NOT NULL
      AND p.prenom IS NOT NULL
      AND p.id NOT IN (SELECT id FROM fusionnes)
),

matchs AS (
    SELECT
        ac.id_ac,
        cn.id_cn,
        ac.nom_n,
        ac.prenom_n,
        ac.code_insee,
        similarity(ac.nom_n, cn.nom_n) AS sim_nom,
        similarity(ac.prenom_n, cn.prenom_n) AS sim_prenom,
        COALESCE(ac.updated_ac, ac.created_ac) AS ts_ac,
        COALESCE(cn.updated_cn, cn.created_cn) AS ts_cn
    FROM ac
    JOIN cn
      ON ac.code_insee = cn.code_insee
     AND ac.id_ac <> cn.id_cn
     AND similarity(ac.nom_n, cn.nom_n) > 0
     AND similarity(ac.prenom_n, cn.prenom_n) > 0
)

SELECT DISTINCT ON (m.id_ac, m.id_cn)
  m.nom_n,
  m.prenom_n,
  m.code_insee,
  m.id_ac,
  m.id_cn,
  ROUND(m.sim_nom::numeric, 3) AS sim_nom,
  ROUND(m.sim_prenom::numeric, 3) AS sim_prenom,
  ROUND(((m.sim_nom + m.sim_prenom) / 2.0)::numeric, 3) AS sim_score,
  to_jsonb(jsonb_strip_nulls(to_jsonb(p_ac))) AS personne_ac,
  to_jsonb(jsonb_strip_nulls(to_jsonb(p_cn))) AS personne_cn,
  CASE
    WHEN m.ts_ac >= m.ts_cn THEN m.id_ac
    ELSE m.id_cn
  END AS winner_id,
  CASE
    WHEN m.ts_ac < m.ts_cn THEN m.id_ac
    ELSE m.id_cn
  END AS loser_id
FROM matchs m
JOIN main.personne p_ac ON p_ac.id = m.id_ac
JOIN main.personne p_cn ON p_cn.id = m.id_cn
ORDER BY m.id_ac, m.id_cn, m.code_insee, m.nom_n, m.prenom_n;
