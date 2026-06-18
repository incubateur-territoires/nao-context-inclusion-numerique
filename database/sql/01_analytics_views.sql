-- Vues analytics complémentaires (lieux, adresses, KPI agrégés).
-- Les entités personne/structure utilisent le schéma llm.* — voir 00_llm_views.sql.
-- À exécuter avec un rôle ayant les droits CREATE sur le schéma analytics.
-- Référence : database/decisions/tier3-analytics-views.md

CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA analytics IS 'Vues anonymisées pour l''agent analytics Nao — sans contact, adresse précise ni identifiants personne.';

-- ---------------------------------------------------------------------------
-- Adresses : commune et département uniquement (pas de voie ni géométrie)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.adresse_publique AS
SELECT
    id,
    code_postal,
    code_insee,
    nom_commune,
    departement,
    created_at,
    updated_at
FROM main.adresse;

COMMENT ON VIEW analytics.adresse_publique IS 'Adresse réduite au niveau communal — sans voie, numéro ni géométrie.';

-- ---------------------------------------------------------------------------
-- Lieux d'inclusion (pas de vue llm.* — analytics uniquement)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.lieu_inclusion_publique AS
SELECT
    id,
    nom,
    adresse_id,
    structure_cartographie_nationale_id,
    visible_pour_cartographie_nationale,
    fiche_acces_libre,
    presentation_resume,
    presentation_detail,
    horaires,
    prise_rdv,
    itinerance,
    services,
    modalites_acces,
    modalites_accompagnement,
    publics_specifiquement_adresses,
    prise_en_charge_specifique,
    frais_a_charge,
    formations_labels,
    autres_formations_labels,
    dispositif_programmes_nationaux,
    typologies,
    mediateurs_en_activite,
    emplois,
    source,
    created_at,
    updated_at,
    structure_coop_id
FROM main.lieu_inclusion;

COMMENT ON VIEW analytics.lieu_inclusion_publique IS 'Lieu d''inclusion sans contact, edited_by ni import_warnings.';

-- ---------------------------------------------------------------------------
-- KPI agrégés personnes (sans personne_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.mediateurs_par_structure AS
SELECT
    pae.structure_administrative_id,
    COUNT(*) FILTER (WHERE pae.est_active) AS nb_affectations_actives,
    COUNT(*) AS nb_affectations_total
FROM main.personne_affectations_emploi pae
GROUP BY pae.structure_administrative_id;

COMMENT ON VIEW analytics.mediateurs_par_structure IS 'Comptages d''affectations emploi par structure — agrégat sans identifiant personne.';

CREATE OR REPLACE VIEW analytics.mediateurs_par_lieu AS
SELECT
    pal.lieu_id,
    COUNT(*) FILTER (WHERE pal.est_active) AS nb_affectations_actives,
    COUNT(*) AS nb_affectations_total
FROM main.personne_affectations_lieu pal
GROUP BY pal.lieu_id;

COMMENT ON VIEW analytics.mediateurs_par_lieu IS 'Comptages d''affectations lieu par lieu d''inclusion — agrégat sans identifiant personne.';

CREATE OR REPLACE VIEW analytics.postes_synthese AS
SELECT
  poste_conum_id,
  structure_id,
  etat,
  typologie,
  est_coordinateur,
  enveloppes,
  date_fin_convention,
  bonification,
  montant_subvention_cumule,
  montant_versement_cumule,
  subvention_v1,
  bonification_v1,
  versement_cumule_v1,
  subvention_v2,
  bonification_v2,
  versement_cumule_v2,
  nb_contrats_en_cours
FROM min.postes_conseiller_numerique_synthese;

COMMENT ON VIEW analytics.postes_synthese IS 'Synthèse postes Conseiller Numérique sans personne_id.';
