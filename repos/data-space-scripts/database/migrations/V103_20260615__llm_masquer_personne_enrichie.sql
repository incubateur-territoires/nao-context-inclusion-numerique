-- ============================================================
-- V103 – Schéma `llm` : masquer min.personne_enrichie (PII oubliée en V102)
-- ============================================================
-- CONTEXTE :
-- V102 a créé le schéma `llm` de vues sans PII pour le rôle read-only nao_ro,
-- mais a OUBLIÉ la vue `min.personne_enrichie`. Comme le rôle dispose d'un
-- GRANT SELECT large sur le schéma `min` (qui couvre aussi les VUES),
-- nao_ro pouvait encore lire `min.personne_enrichie` → exposition de
-- prenom, nom, contact (jsonb), edited_by, deleted_by.
--
-- On ajoute une vue curée `llm.personne_enrichie` (sans PII, en gardant les
-- flags d'enrichissement non nominatifs) et on révoque l'accès direct de
-- nao_ro à `min.personne_enrichie`.
--
-- `min.personne_enrichie` est une vue créée par Flyway (cf. V092), colonnes
-- identiques en CI et prod → liste statique (pas d'allowlist dynamique comme
-- pour les TABLES min.* gérées par Prisma).
--
-- GRANT/REVOKE encadrés par un test d'existence du rôle (no-op en CI/test).
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

-- 1. Vue curée ---------------------------------------------------------------
-- PII supprimées : prenom, nom, contact (jsonb), edited_by, deleted_by.
CREATE OR REPLACE VIEW llm.personne_enrichie
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
    type_accompagnateur,
    labellisation_aidant_connect,
    est_actuellement_mediateur_en_poste,
    est_actuellement_aidant_numerique_en_poste,
    est_actuellement_conseiller_numerique,
    est_actuellement_coordo_actif,
    structure_employeuse_id,
    created_at,
    updated_at,
    deleted_at
FROM min.personne_enrichie;

-- 2. min.contact_membre_gouvernance : retirer l'exposition résiduelle --------
-- V102 exposait llm.contact_membre_gouvernance, mais sa seule colonne non
-- supprimée était `fonction`. La table est 100% PII et la vue de très faible
-- intérêt → on cesse complètement de l'exposer. (L'accès direct à la table de
-- base reste révoqué depuis V102.)
DROP VIEW IF EXISTS llm.contact_membre_gouvernance;

-- 3. Droits nao_ro (no-op si le rôle n'existe pas — CI/test) -----------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON llm.personne_enrichie TO nao_ro;
    REVOKE SELECT ON min.personne_enrichie FROM nao_ro;
  END IF;
END
$$;
