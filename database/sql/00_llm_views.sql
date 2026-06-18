-- Vues llm.* sans données personnelles pour le rôle nao_ro.
-- À exécuter avec un rôle ayant les droits CREATE sur les schémas main et min.
-- Référence : agent/semantics/privacy.md

CREATE SCHEMA IF NOT EXISTS llm;

COMMENT ON SCHEMA llm IS 'Vues anonymisées pour l''agent analytics Nao — même grain que les tables sources, colonnes PII retirées.';

-- ---------------------------------------------------------------------------
-- main.personne → llm.personne
-- Retiré : prenom, nom, contact, edited_by, deleted_by
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.personne AS
SELECT
    id,
    aidant_connect_id,
    conseiller_numerique_id,
    cn_pg_id,
    coop_id,
    is_coordinateur,
    is_mediateur,
    formation_fne_ac,
    profession_ac,
    nb_accompagnements_ac,
    created_at,
    updated_at,
    deleted_at,
    is_referent_ac,
    updated_at_ac,
    is_visible,
    updated_at_coop,
    updated_at_idposte
FROM main.personne;

COMMENT ON VIEW llm.personne IS 'Personne sans identité ni coordonnées — conserve les identifiants métier et statuts.';

-- ---------------------------------------------------------------------------
-- main.contact → llm.contact
-- Retiré : nom, prenom, email, telephone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.contact AS
SELECT
    id,
    fonction,
    est_referent_fne,
    created_at,
    updated_at
FROM main.contact;

COMMENT ON VIEW llm.contact IS 'Contact structurel sans identité ni coordonnées.';

-- ---------------------------------------------------------------------------
-- main.structure_administrative → llm.structure_administrative
-- Retiré du jsonb contact : nom, prenom, email, courriel(s) — garde site_web et telephone org
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.structure_administrative AS
SELECT
    id,
    old_main_structure_id,
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
    CASE
        WHEN contact IS NULL THEN NULL
        ELSE contact - 'nom' - 'prenom' - 'email' - 'courriel' - 'courriels'
    END AS contact,
    deleted_at,
    last_sirene_enrich_at,
    created_at,
    updated_at,
    updated_at_coop,
    updated_at_idposte,
    updated_at_ac
FROM main.structure_administrative
WHERE deleted_at IS NULL;

COMMENT ON VIEW llm.structure_administrative IS 'Structure administrative sans référent nommé — contact limité à site_web et téléphone organisation.';

-- ---------------------------------------------------------------------------
-- min.utilisateur → llm.utilisateur
-- Retiré : nom, prenom, email_de_contact, sso_email, sso_id, telephone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.utilisateur AS
SELECT
    id,
    date_de_creation,
    departement_code,
    derniere_connexion,
    groupement_id,
    invite_le,
    is_super_admin,
    is_supprime,
    region_code,
    role,
    old_structure_id,
    structure_id
FROM min.utilisateur;

COMMENT ON VIEW llm.utilisateur IS 'Utilisateur MIN sans identité ni coordonnées — conserve rôle et rattachement territorial.';

-- ---------------------------------------------------------------------------
-- min.structure → llm.structure
-- Retiré : contact jsonb (référent nommé), adresse postale
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.structure AS
SELECT
    id,
    code_postal,
    commune,
    departement_code,
    identifiant_etablissement,
    id_mongo,
    nom,
    statut,
    type,
    categorie_juridique
FROM min.structure;

COMMENT ON VIEW llm.structure IS 'Structure MIN sans référent nommé ni adresse postale.';

-- ---------------------------------------------------------------------------
-- min.membre → llm.membre
-- Retiré : contact, contact_technique (emails personnels)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.membre AS
SELECT
    id,
    gouvernance_departement_code,
    type,
    statut,
    old_uuid,
    is_coporteur,
    categorie_membre,
    nom,
    siret_ridet,
    date_suppression,
    old_structure_id,
    structure_id
FROM min.membre;

COMMENT ON VIEW llm.membre IS 'Membre gouvernance sans coordonnées personnelles.';

-- ---------------------------------------------------------------------------
-- min.personne_enrichie → llm.personne_enrichie
-- Retiré : prenom, nom, contact, edited_by, deleted_by
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW llm.personne_enrichie AS
SELECT
    id,
    aidant_connect_id,
    conseiller_numerique_id,
    cn_pg_id,
    coop_id,
    is_coordinateur,
    is_mediateur,
    formation_fne_ac,
    profession_ac,
    nb_accompagnements_ac,
    created_at,
    updated_at,
    deleted_at,
    type_accompagnateur,
    labellisation_aidant_connect,
    est_actuellement_mediateur_en_poste,
    est_actuellement_aidant_numerique_en_poste,
    est_actuellement_conseiller_numerique,
    est_actuellement_coordo_actif,
    structure_employeuse_id
FROM min.personne_enrichie;

COMMENT ON VIEW llm.personne_enrichie IS 'Personne enrichie MIN sans identité ni coordonnées — conserve les indicateurs d''activité.';
