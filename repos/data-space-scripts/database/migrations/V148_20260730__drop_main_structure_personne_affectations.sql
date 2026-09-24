-- ============================================================
-- V148 – DROP du legacy main.structure / main.personne_affectations (N11)
-- ============================================================
-- Point final de la refonte structure_administrative / lieu_inclusion
-- (docs/refonte-structure-plan.md, chantier N11). Les deux tables ne sont
-- plus ni écrites ni lues :
--   - DAGs basculés (phases 3-4), consommateurs api.*/dataviz.*/min.*
--     basculés (phase 5, V085-V098), sirene-backfill et opendata débranchés
--     (MRs !943 / !945), rapports CI/CD basculés.
--   - Validation d'intégrité (2026-07-29, dataspace_dev) : les 28 755 lignes
--     legacy = 26 592 couvertes par old_main_structure_id + 1 330 retrouvées
--     via siret/carto_id/coop_id (fusions) + 833 départs de flux légitimes.
--     0 référence min.utilisateur / min.membre.
--
-- ⚠️ IRRÉVERSIBLE sans pg_restore : prendre un dump prod frais juste avant
-- le merge (cf U148).
--
-- Ordre : fonctions et vues dépendantes d'abord, puis les tables SANS
-- CASCADE — si un dépendant inattendu subsiste, la migration échoue au lieu
-- de le supprimer silencieusement.

-- 1) Fonction legacy des similarities-merge (DAGs supprimés en !943).
--    Aucun appelant : ni MIN (qui utilise merge_structure_administrative),
--    ni scripts, ni DAGs. NB : main.merge_structure a déjà été supprimée
--    par V144 (#1805) — seul merge_personne reste à dropper ici.
DROP FUNCTION IF EXISTS main.merge_structure(integer, integer);
DROP FUNCTION IF EXISTS main.merge_personne(integer, integer);

-- 2) Vues legacy hors Flyway (créées à la main avant la mise en place des
--    migrations ; owner sonum). Elles lisent main.structure (données figées
--    depuis la bascule de mai), plus aucun consommateur identifié.
--    dataviz.data_errors (candidate Metabase) est une projection de
--    public.data_errors — vérifié avant merge qu'aucun dashboard ne la lit.
DROP VIEW IF EXISTS public.geo_struct;
DROP VIEW IF EXISTS dataviz.data_errors;
DROP VIEW IF EXISTS public.data_errors;

-- 3) Les tables. personne_affectations d'abord (FK vers structure).
DROP TABLE main.personne_affectations;
DROP TABLE main.structure;
