-- ============================================================
-- V159 – SEPT #1707 / #1724 lot 2 : fin de l'import des structures coop par
--   API — drop de source.coop__activites, source.coop__structures,
--   staging.coop__structures ; purge des rejets du flux.
-- ============================================================
-- Depuis V153 la vue d'union main.lieu_inclusion lit coop.lieu_inclusion en
-- direct ; V155 fournit main.trouver_ou_creer_adresse_lieu. Le coop-dag ne
-- maintient plus que l'IDENTITÉ des lieux dans main.lieu_inclusion_registre,
-- par un filet SQL direct sur coop.lieu_inclusion
-- (etl/load/registre_lieux_coop.py, même MR) : plus de fetch
-- /api/v1/structures, plus de géocodage BAN, plus de silver.
--
-- source.coop__activites : orpheline depuis V144 (fetch_all_activites retiré,
-- silver droppé, le bronze avait été oublié) — 415 k lignes / 566 MB sur dev.
-- source.coop__structures : 272 k lignes / 342 MB, 51 runs de stock complet.
--
-- Pourquoi pas de bronze pour ce flux : les trois finalités de la couche
-- source (rejouer un run, tracer reçu vs chargé, auditer l'évolution — V099)
-- sont mieux servies par les tables coop elles-mêmes, dans le même cluster
-- (creation / modification / suppression). Une capture JSON quotidienne
-- d'une table qu'on peut SELECT est une redondance — de PII pour les
-- utilisateurs. Exception documentée dans approche-data/01 et 19 ; le bronze
-- reste le standard pour toute source EXTERNE au cluster.
--
-- staging.rejets : les rejets du flux coop__structures (payloads bruts) ne
-- sont plus actionnables — purgés. source.coop__utilisateurs et son silver
-- suivent dans la MR de retrait du flux utilisateurs.
-- ------------------------------------------------------------

DROP TABLE IF EXISTS source.coop__activites;
DROP TABLE IF EXISTS source.coop__structures;
DROP TABLE IF EXISTS staging.coop__structures;

DELETE FROM staging.rejets WHERE flux = 'coop__structures';
