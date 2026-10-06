-- ============================================================
-- V177 – SEPT #2013 : nettoyage des résidus de la refonte structure administrative
-- ============================================================
-- Tour d'horizon post-refonte (docs/refonte-structure-plan.md, N4 / N6 / N11)
-- du 2026-09-30 : objets sans plus aucun écrivain ni lecteur (dataspace, MIN,
-- coop), vérifiés un par un (grep code + dépendances pg_depend).
--
--   1. api.structures (vue de compat V087, chantier N6) : seul le rôle
--      postgrest_anct_dev (« dev tests ») y avait accès, et son unique jeton a
--      expiré le 2025-12-31. Data Inclusion consomme api.carto (sur
--      main.lieu_inclusion), non touchée. Le rôle est retiré avec la vue.
--   2. main.personne_affectations_lieu_legacy : réplique GELÉE par V151
--      (« drop prévu dans une migration ultérieure »), plus lue ni écrite.
--   3. import.cn_* / import.ac_mandats (V001, vides, jamais relues) et
--      import.coop_structures_temp (créée hors Flyway, absente en CI).
--   4. min.structure (ancien référentiel MIN, remplacé par
--      main.structure_administrative depuis V085/V086) + sa vue llm.structure,
--      et les colonnes min.membre.old_structure_id /
--      min.utilisateur.old_structure_id qui y renvoyaient. Les vues
--      llm.membre / llm.utilisateur les exposaient : elles sont recréées sans
--      (même allowlist dynamique que V102, commentaires V172 et grant nao_ro
--      reposés).
--      ⚠️ Séquencement : Prisma lit toutes les colonnes d'un modèle — la PR MIN
--      qui retire StructureRecord et oldStructureId doit être DÉPLOYÉE avant le
--      merge de cette migration (appliquée automatiquement en prod).
--   5. Schéma pseudonymisation (hors Flyway, écrit uniquement par le DAG
--      db_pseudonym_export, cassé depuis V148 et supprimé dans la même MR) :
--      chantier abandonné, à reprendre de zéro.
--
-- Ordre : dépendants d'abord, puis les objets SANS CASCADE (patron V148) — si
-- un dépendant inattendu subsiste en prod, la migration échoue au lieu de le
-- supprimer silencieusement.
--
-- ⚠️ IRRÉVERSIBLE pour les données (cf U177).

-- 1) api.structures + rôle postgrest_anct_dev --------------------------------
DROP VIEW IF EXISTS api.structures;

UPDATE auth.token SET active = false WHERE pg_role = 'postgrest_anct_dev';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest_anct_dev') THEN
    REVOKE USAGE ON SCHEMA api FROM postgrest_anct_dev;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_api') THEN
      REVOKE postgrest_anct_dev FROM app_api;
    END IF;
    -- Les rôles sont globaux au cluster : si postgrest_anct_dev porte encore
    -- des droits dans une autre base, on le laisse (inoffensif, plus aucun
    -- droit ici) plutôt que de bloquer la migration.
    BEGIN
      DROP ROLE postgrest_anct_dev;
    EXCEPTION WHEN dependent_objects_still_exist THEN
      RAISE NOTICE 'Rôle postgrest_anct_dev conservé : droits restants hors de cette base (%).', SQLERRM;
    END;
  END IF;
END
$$;

-- 2) Réplique gelée des affectations lieu (V151) ------------------------------
DROP TABLE IF EXISTS main.personne_affectations_lieu_legacy;

-- 3) Imports bruts orphelins --------------------------------------------------
DROP TABLE IF EXISTS
  import.cn_conseillers,
  import.cn_cras,
  import.cn_permanences,
  import.cn_relations,
  import.cn_structures,
  import.ac_mandats,
  import.coop_structures_temp;

-- 4) min.structure et les colonnes old_structure_id ---------------------------
DROP VIEW IF EXISTS llm.structure;
DROP VIEW IF EXISTS llm.membre;
DROP VIEW IF EXISTS llm.utilisateur;

ALTER TABLE min.membre      DROP COLUMN IF EXISTS old_structure_id;
ALTER TABLE min.utilisateur DROP COLUMN IF EXISTS old_structure_id;

DROP TABLE IF EXISTS min.structure;

-- Recréation à l'identique de V102, old_structure_id retiré des allowlists
-- (seules les colonnes réellement présentes sont exposées : CI ET prod).
-- PII exclues : nom, prenom, email_de_contact, sso_email, sso_id, telephone.
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY a.ord)
    INTO cols
  FROM unnest(ARRAY[
         'id','role','date_de_creation','derniere_connexion','invite_le',
         'is_super_admin','is_supprime','departement_code','region_code',
         'groupement_id','structure_id'
       ]) WITH ORDINALITY AS a(name, ord)
  JOIN information_schema.columns c
    ON c.table_schema = 'min' AND c.table_name = 'utilisateur'
   AND c.column_name = a.name;
  EXECUTE format(
    'CREATE VIEW llm.utilisateur WITH (security_invoker = false) AS SELECT %s FROM min.utilisateur',
    cols);
END
$$;

-- `contact` et `contact_technique` (text) = emails personnels. Exclus.
DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY a.ord)
    INTO cols
  FROM unnest(ARRAY[
         'id','gouvernance_departement_code','type','statut','categorie_membre',
         'is_coporteur','nom','siret_ridet','old_uuid','structure_id',
         'date_suppression'
       ]) WITH ORDINALITY AS a(name, ord)
  JOIN information_schema.columns c
    ON c.table_schema = 'min' AND c.table_name = 'membre'
   AND c.column_name = a.name;
  EXECUTE format(
    'CREATE VIEW llm.membre WITH (security_invoker = false) AS SELECT %s FROM min.membre',
    cols);
END
$$;

COMMENT ON VIEW llm.membre IS
  'Membres des gouvernances departementales. id = identifiant metier TEXTE '
  '(ex. epci-200068641-31), pas un entier. structure_id pointe une structure '
  'administrative.';

COMMENT ON COLUMN llm.membre.statut IS
  'candidat | confirme | supprimer. Suppression LOGIQUE : la ligne reste en base, '
  'seul le statut bascule et date_suppression se remplit. Ne jamais conclure a une '
  'suppression, ni a une absence, sans avoir lu cette colonne.';

COMMENT ON VIEW llm.utilisateur IS
  'Comptes de l''application MIN, identite masquee (V102) : ni nom, ni prenom, ni '
  'courriel, ni telephone, ni sso_id. Cible des user_id de llm.evenement. '
  'Suppression logique via is_supprime. Restituer un acteur par son id, son role '
  'et son departement — ne jamais inventer une identite.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON llm.membre, llm.utilisateur TO nao_ro;
  END IF;
END
$$;

-- 5) Schéma pseudonymisation (hors Flyway) ------------------------------------
DROP TABLE IF EXISTS
  pseudonymisation.main_personne,
  pseudonymisation.main_structure,
  pseudonymisation.main_contact,
  pseudonymisation.main_contact_structure,
  pseudonymisation.min_utilisateur,
  pseudonymisation.min_membre,
  pseudonymisation.min_contact_membre_gouvernance,
  pseudonymisation.min_comite,
  pseudonymisation.min_feuille_de_route,
  pseudonymisation.min_gouvernance,
  pseudonymisation.nom,
  pseudonymisation.prenom;

DROP FUNCTION IF EXISTS pseudonymisation.generate_email(character varying, character varying);
DROP FUNCTION IF EXISTS pseudonymisation.generate_nom();
DROP FUNCTION IF EXISTS pseudonymisation.generate_prenom();
DROP FUNCTION IF EXISTS pseudonymisation.generate_phone_number();

DROP SCHEMA IF EXISTS pseudonymisation;

NOTIFY pgrst, 'reload schema';
