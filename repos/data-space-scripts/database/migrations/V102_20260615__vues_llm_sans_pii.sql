-- ============================================================
-- V102 – Schéma `llm` : vues sans PII pour un outil LLM (rôle nao_ro)
-- ============================================================
-- CONTEXTE :
-- On branche un outil LLM en lecture seule (rôle nao_ro, read-only) sur
-- l'entrepôt. Objectif RGPD : aucune donnée personnelle nominative ne doit
-- être exposée au LLM. On crée un schéma `llm` de vues curées des tables
-- sensibles, et on RETIRE à nao_ro l'accès direct aux tables de base PII.
--
-- STRATÉGIE : suppression TOTALE des colonnes nominatives
--   (nom, prénom, email, téléphone, sso_id, jsonb `contact`/`contact_technique`).
--
-- MÉCANISME : une vue lit ses tables sous-jacentes avec les droits de SON
--   PROPRIÉTAIRE (security_invoker = false, défaut — cf. V091). nao_ro n'a
--   donc AUCUN droit direct sur les tables de base : il ne voit que les
--   colonnes exposées ici.
--
-- TABLES TRAITÉES :
--   main.personne, main.contact, main.structure_administrative,
--   min.utilisateur, min.contact_membre_gouvernance, min.structure, min.membre.
-- main.structure : pas de vue (table en voie de disparition, cf. refonte SA/LI),
--   accès direct révoqué pour ne pas exposer son `contact` PII.
-- main.lieu_inclusion : `contact` = coordonnées publiques anonymes (cf. V069),
--   AUCUN nom/prénom → accès direct conservé, pas de vue.
--
-- GRANTS nao_ro : encadrés par un test d'existence du rôle (no-op en CI/test
--   où nao_ro n'existe pas ; actifs en prod une fois le rôle créé).
--   Le rôle nao_ro + mot de passe est créé HORS Flyway
--   (scripts/create_user_nao_readonly.sql, secret, spécifique prod).
--
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

CREATE SCHEMA IF NOT EXISTS llm;

-- 1. main.personne -----------------------------------------------------------
-- PII supprimées : prenom, nom, contact (jsonb), edited_by, deleted_by.
CREATE OR REPLACE VIEW llm.personne
  WITH (security_invoker = false) AS
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
    is_referent_ac,
    is_visible,
    created_at,
    updated_at,
    updated_at_ac,
    updated_at_coop,
    updated_at_idposte,
    deleted_at
FROM main.personne;

-- 2. main.contact ------------------------------------------------------------
-- PII supprimées : nom, prenom, email, telephone.
CREATE OR REPLACE VIEW llm.contact
  WITH (security_invoker = false) AS
SELECT
    id,
    fonction,
    est_referent_fne,
    created_at,
    updated_at
FROM main.contact;

-- 3. min.utilisateur ---------------------------------------------------------
-- ⚠️ Schéma `min` géré par Prisma : la baseline Flyway (V008) ignore les
-- colonnes ajoutées par Prisma en prod (ex. old_structure_id). On construit
-- donc la liste de colonnes dynamiquement depuis une ALLOWLIST non-PII : seules
-- les colonnes RÉELLEMENT présentes sont exposées (compatible CI ET prod, et une
-- future colonne non whitelistée n'apparaît pas → pas de fuite par défaut).
-- PII exclues : nom, prenom, email_de_contact, sso_email, sso_id, telephone.
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY a.ord)
    INTO cols
  FROM unnest(ARRAY[
         'id','role','date_de_creation','derniere_connexion','invite_le',
         'is_super_admin','is_supprime','departement_code','region_code',
         'groupement_id','structure_id','old_structure_id'
       ]) WITH ORDINALITY AS a(name, ord)
  JOIN information_schema.columns c
    ON c.table_schema = 'min' AND c.table_name = 'utilisateur'
   AND c.column_name = a.name;
  EXECUTE format(
    'CREATE OR REPLACE VIEW llm.utilisateur WITH (security_invoker = false) AS SELECT %s FROM min.utilisateur',
    cols);
END
$$;

-- 4. min.contact_membre_gouvernance -----------------------------------------
-- Table 100% PII (email, prenom, nom, fonction) et sans clé. Il ne reste que
-- `fonction`. Vue de faible intérêt (conservée pour cohérence / dénombrement).
CREATE OR REPLACE VIEW llm.contact_membre_gouvernance
  WITH (security_invoker = false) AS
SELECT
    fonction
FROM min.contact_membre_gouvernance;

-- 5. main.structure_administrative -------------------------------------------
-- `contact` jsonb : ~1185/4276 lignes avec nom/prénom + emails perso.
-- On supprime nom/prenom/courriels ; on ne garde que site_web + telephone
-- (niveau organisation). edited_by / deleted_by retirés.
CREATE OR REPLACE VIEW llm.structure_administrative
  WITH (security_invoker = false) AS
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
    contact ->> 'site_web'   AS contact_site_web,
    contact ->> 'telephone'  AS contact_telephone,
    last_sirene_enrich_at,
    created_at,
    updated_at,
    updated_at_coop,
    updated_at_idposte,
    updated_at_ac,
    deleted_at
FROM main.structure_administrative;

-- 6. min.structure -----------------------------------------------------------
-- `contact` jsonb : ~5228/5235 = personne nommée (email/tel perso). Supprimé.
-- adresse/cp/commune/nom = niveau organisation (public). Allowlist dynamique
-- (cf. note section 3 ; categorie_juridique n'existe qu'en prod). PII exclue : contact.
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY a.ord)
    INTO cols
  FROM unnest(ARRAY[
         'id','nom','type','statut','categorie_juridique',
         'identifiant_etablissement','id_mongo','adresse','code_postal',
         'commune','departement_code'
       ]) WITH ORDINALITY AS a(name, ord)
  JOIN information_schema.columns c
    ON c.table_schema = 'min' AND c.table_name = 'structure'
   AND c.column_name = a.name;
  EXECUTE format(
    'CREATE OR REPLACE VIEW llm.structure WITH (security_invoker = false) AS SELECT %s FROM min.structure',
    cols);
END
$$;

-- 7. min.membre --------------------------------------------------------------
-- `contact` et `contact_technique` (text) = emails personnels. Exclus.
-- Allowlist dynamique (cf. note section 3 ; siret_ridet/old_structure_id/
-- structure_id/date_suppression n'existent qu'en prod).
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY a.ord)
    INTO cols
  FROM unnest(ARRAY[
         'id','gouvernance_departement_code','type','statut','categorie_membre',
         'is_coporteur','nom','siret_ridet','old_uuid','old_structure_id',
         'structure_id','date_suppression'
       ]) WITH ORDINALITY AS a(name, ord)
  JOIN information_schema.columns c
    ON c.table_schema = 'min' AND c.table_name = 'membre'
   AND c.column_name = a.name;
  EXECUTE format(
    'CREATE OR REPLACE VIEW llm.membre WITH (security_invoker = false) AS SELECT %s FROM min.membre',
    cols);
END
$$;

-- 8. Droits nao_ro (no-op si le rôle n'existe pas — CI/test) -----------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    -- Lecture des vues curées
    GRANT USAGE ON SCHEMA llm TO nao_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA llm TO nao_ro;

    -- Révocation de l'accès direct aux tables de base PII
    REVOKE SELECT ON main.personne                  FROM nao_ro;
    REVOKE SELECT ON main.contact                   FROM nao_ro;
    REVOKE SELECT ON main.structure_administrative  FROM nao_ro;
    REVOKE SELECT ON main.structure                 FROM nao_ro;  -- disparition à venir
    REVOKE SELECT ON min.utilisateur                FROM nao_ro;
    REVOKE SELECT ON min.contact_membre_gouvernance FROM nao_ro;
    REVOKE SELECT ON min.structure                  FROM nao_ro;
    REVOKE SELECT ON min.membre                     FROM nao_ro;
  END IF;
END
$$;
