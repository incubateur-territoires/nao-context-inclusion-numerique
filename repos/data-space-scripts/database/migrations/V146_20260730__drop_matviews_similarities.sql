-- ============================================================
-- V146 – Drop des matviews de détection des similarities-merge
-- ============================================================
-- Les DAGs structures-similarities-merge et personne-similarities-merge sont
-- décommissionnés (refonte N11 / N5 : dédup absorbée par les contraintes
-- UNIQUE du nouveau modèle ; reliquat personnes AC ↔ Coop documenté en N13 du
-- plan). Leurs matviews de détection lisaient main.structure /
-- main.personne_affectations (legacy, figées) et ne sont plus rafraîchies par
-- personne.

DROP MATERIALIZED VIEW IF EXISTS dataviz.structure_similarities;
DROP MATERIALIZED VIEW IF EXISTS dataviz.personne_similarities;
