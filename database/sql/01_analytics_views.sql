-- Vues analytics sans données personnelles pour le contexte Nao.
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
-- Structures administratives (refonte 2026)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.structure_administrative_publique AS
SELECT
    id,
    siret,
    ridet,
    denomination_sirene,
    rna,
    denomination_antenne,
    adresse_id,
    structure_coop_id,
    structure_tp_id,
    structure_ac_id,
    etat_administratif,
    code_activite_principale,
    categorie_juridique,
    publique,
    nb_mandats_ac,
    last_sirene_enrich_at,
    created_at,
    updated_at,
    updated_at_coop,
    updated_at_idposte,
    updated_at_ac
FROM main.structure_administrative
WHERE deleted_at IS NULL;

COMMENT ON VIEW analytics.structure_administrative_publique IS 'Structure administrative sans contact ni métadonnées d''édition/suppression.';

-- ---------------------------------------------------------------------------
-- Structures legacy (main.structure)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.structure_publique AS
SELECT
    id,
    structure_coop_id,
    structure_ac_id,
    structure_tp_id,
    nom,
    denomination_sirene,
    siret,
    rna,
    adresse_id,
    etat_administratif,
    code_activite_principale,
    categorie_juridique,
    nb_mandats_ac,
    publique,
    structure_cartographie_nationale_id,
    visible_pour_cartographie_nationale,
    typologies,
    presentation_resume,
    presentation_detail,
    horaires,
    prise_rdv,
    services,
    publics_specifiquement_adresses,
    prise_en_charge_specifique,
    frais_a_charge,
    dispositif_programmes_nationaux,
    formations_labels,
    autres_formations_labels,
    itinerance,
    modalites_acces,
    modalites_accompagnement,
    mediateurs_en_activite,
    emplois,
    source,
    last_sirene_enrich_at,
    created_at,
    updated_at,
    fiche_acces_libre
FROM main.structure
WHERE deleted_at IS NULL;

COMMENT ON VIEW analytics.structure_publique IS 'Structure legacy sans contact ni métadonnées d''édition/suppression.';

-- ---------------------------------------------------------------------------
-- Lieux d'inclusion
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
-- Structures MIN (application gouvernance)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.min_structure_publique AS
SELECT
    id,
    code_postal,
    commune,
    departement_code,
    identifiant_etablissement,
    nom,
    statut,
    type,
    categorie_juridique
FROM min.structure;

COMMENT ON VIEW analytics.min_structure_publique IS 'Structure MIN sans adresse postale ni contact.';

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
