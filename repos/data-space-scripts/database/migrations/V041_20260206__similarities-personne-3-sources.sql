-- Ajout de la colonne match_type à la table d'audit
ALTER TABLE audit.personne_merge_log
ADD COLUMN IF NOT EXISTS match_type text NULL;

DROP MATERIALIZED VIEW IF EXISTS dataviz.personne_similarities;

-- Description:
-- Vue matérialisée listant les paires potentielles de personnes à fusionner
-- entre Aidants Connect, Conseiller Numérique et Coop.
-- 3 croisements : AC ↔ CN, AC ↔ COOP, CN ↔ COOP

CREATE MATERIALIZED VIEW dataviz.personne_similarities AS

-- Personnes totalement fusionnées (à exclure)
WITH fusionnes AS (
    SELECT id
    FROM main.personne
    WHERE cn_pg_id IS NOT NULL
      AND aidant_connect_id IS NOT NULL
      AND coop_id IS NOT NULL
),

-- Base commune : personne avec structure d'emploi
base AS (
    SELECT
        p.id,
        p.aidant_connect_id,
        p.cn_pg_id,
        p.coop_id,
        unaccent(lower(trim(p.nom)))     AS nom_n,
        unaccent(lower(trim(p.prenom)))  AS prenom_n,
        a.code_insee,
        COALESCE(p.updated_at, p.created_at) AS ts
    FROM main.personne p
    JOIN main.personne_affectations pa ON pa.personne_id = p.id
    JOIN main.structure s              ON s.id = pa.structure_id
    JOIN main.adresse a                ON a.id = s.adresse_id
    WHERE pa.suppression IS NULL
      AND pa.type = 'structure_emploi'
      AND p.nom IS NOT NULL
      AND p.prenom IS NOT NULL
      AND p.id NOT IN (SELECT id FROM fusionnes)
),

-- Source AC
ac AS (
    SELECT * FROM base WHERE aidant_connect_id IS NOT NULL
),

-- Source CN
cn AS (
    SELECT * FROM base WHERE cn_pg_id IS NOT NULL
),

-- Source COOP
coop AS (
    SELECT * FROM base WHERE coop_id IS NOT NULL
),

-- Croisement AC ↔ CN
matchs_ac_cn AS (
    SELECT
        ac.id AS id_1,
        cn.id AS id_2,
        'AC_CN' AS match_type,
        ac.nom_n,
        ac.prenom_n,
        ac.code_insee,
        similarity(ac.nom_n, cn.nom_n) AS sim_nom,
        similarity(ac.prenom_n, cn.prenom_n) AS sim_prenom,
        ac.ts AS ts_1,
        cn.ts AS ts_2
    FROM ac
    JOIN cn
      ON ac.code_insee = cn.code_insee
     AND ac.id <> cn.id
     AND similarity(ac.nom_n, cn.nom_n) > 0
     AND similarity(ac.prenom_n, cn.prenom_n) > 0
),

-- Croisement AC ↔ COOP
matchs_ac_coop AS (
    SELECT
        ac.id AS id_1,
        coop.id AS id_2,
        'AC_COOP' AS match_type,
        ac.nom_n,
        ac.prenom_n,
        ac.code_insee,
        similarity(ac.nom_n, coop.nom_n) AS sim_nom,
        similarity(ac.prenom_n, coop.prenom_n) AS sim_prenom,
        ac.ts AS ts_1,
        coop.ts AS ts_2
    FROM ac
    JOIN coop
      ON ac.code_insee = coop.code_insee
     AND ac.id <> coop.id
     AND similarity(ac.nom_n, coop.nom_n) > 0
     AND similarity(ac.prenom_n, coop.prenom_n) > 0
),

-- Croisement CN ↔ COOP
matchs_cn_coop AS (
    SELECT
        cn.id AS id_1,
        coop.id AS id_2,
        'CN_COOP' AS match_type,
        cn.nom_n,
        cn.prenom_n,
        cn.code_insee,
        similarity(cn.nom_n, coop.nom_n) AS sim_nom,
        similarity(cn.prenom_n, coop.prenom_n) AS sim_prenom,
        cn.ts AS ts_1,
        coop.ts AS ts_2
    FROM cn
    JOIN coop
      ON cn.code_insee = coop.code_insee
     AND cn.id <> coop.id
     AND similarity(cn.nom_n, coop.nom_n) > 0
     AND similarity(cn.prenom_n, coop.prenom_n) > 0
),

-- Union des 3 croisements
all_matchs AS (
    SELECT * FROM matchs_ac_cn
    UNION ALL
    SELECT * FROM matchs_ac_coop
    UNION ALL
    SELECT * FROM matchs_cn_coop
)

SELECT DISTINCT ON (m.id_1, m.id_2)
    m.match_type,
    m.nom_n,
    m.prenom_n,
    m.code_insee,
    m.id_1,
    m.id_2,
    ROUND(m.sim_nom::numeric, 3) AS sim_nom,
    ROUND(m.sim_prenom::numeric, 3) AS sim_prenom,
    ROUND(((m.sim_nom + m.sim_prenom) / 2.0)::numeric, 3) AS sim_score,
    to_jsonb(jsonb_strip_nulls(to_jsonb(p1))) AS personne_1,
    to_jsonb(jsonb_strip_nulls(to_jsonb(p2))) AS personne_2,
    CASE
        WHEN m.ts_1 >= m.ts_2 THEN m.id_1
        ELSE m.id_2
    END AS winner_id,
    CASE
        WHEN m.ts_1 < m.ts_2 THEN m.id_1
        ELSE m.id_2
    END AS loser_id
FROM all_matchs m
JOIN main.personne p1 ON p1.id = m.id_1
JOIN main.personne p2 ON p2.id = m.id_2
ORDER BY m.id_1, m.id_2, m.sim_nom DESC, m.sim_prenom DESC;
