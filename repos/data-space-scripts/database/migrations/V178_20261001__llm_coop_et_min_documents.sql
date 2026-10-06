-- ============================================================
-- V178 – Schéma `llm` : ouvrir la réplique Coop et deux tables MIN à nao_ro
-- ============================================================
-- CONTEXTE (#1591, suite de V102/V103/V172/V173/V177) :
-- L'outil LLM de support (Nao, rôle read-only nao_ro) ne voit pas :
--   1. min.feuille_de_route_document (V140) et min.membre_transfert_log (V106),
--      créées après V102 sans grant nao_ro. La première ne porte que des noms de
--      fichiers ; la seconde porte `par_utilisateur` = sso_id de l'utilisateur
--      MIN (clé nominative retirée par V102) → vue qui le remplace par l'id.
--   2. Le schéma `coop` (réplique Prisma de la Coop de la médiation numérique,
--      44 tables), jamais ouvert : impossible de répondre à « ce médiateur a-t-il
--      un compte, dans quelle équipe, quels lieux a-t-il déclarés ? ».
--
-- STRATÉGIE : même patron que V102/V173 — AUCUN grant sur le schéma `coop`.
-- Des vues curées `llm.coop_<table>` en security_invoker = false, lues avec les
-- droits du propriétaire (rôle Flyway, propriétaire du schéma coop).
-- Audit colonne à colonne du 01/10/2026 (24 tables métier, texte libre
-- échantillonné) :
--   * users : identité, courriel, téléphone, photo, localisation, titre et
--     description retirés ; restent rôle, dates, drapeaux d'inscription, siret.
--   * beneficiaires : prenom, nom, telephone, email, adresse, notes retirés ;
--     annee_naissance retirée aussi (commune + genre + année = ré-identifiable).
--   * structure_administrative / lieu_inclusion (versions Coop) : référent
--     nommé (nom / courriel / téléphone) retiré ; `courriels` du lieu retiré
--     (mélange d'adresses de personnes, cf. V173 sur le registre) ;
--     presentation_* retirés ; textes courts masqués (llm.masquer_coordonnees).
--   * activites : `notes` et `precisions_demarche` (texte libre, noms d'usagers
--     relevés) retirés ; titre_atelier masqué.
--   * activite_coordination : `notes` retiré, champs « autre » et nom masqués.
--   * tags : description masquée.
--   * cras_conseiller_numerique_v1 : `annotation` (texte libre) retirée.
--   * rdvs : `raw_data` (charge utile brute RDV Service Public, usagers
--     nominatifs) et `context` retirés ; name masqué.
--   * rdv_organisations : `email` mis à NULL quand il est de forme prenom.nom@
--     (minorité d'adresses nominatives mêlées aux adresses génériques) ;
--     `phone_number` retiré (mélange accueil / mobile personnel d'agent).
--   * rdv_motifs : `instruction_for_rdv` non exposée (instructions signées
--     nominativement par des agents).
--   * invitations_equipes : `email` de l'invité retiré.
-- Tables NON exposées (secrets, sessions, usagers RDV, technique) : accounts,
-- sessions, verification_tokens, api_clients, rdv_accounts,
-- rdv_webhook_endpoints, rdv_users, rdv_user_profiles, rdv_sync_logs, uploads,
-- images, job_executions, maintenances, mutations, v1_repair_*,
-- _prisma_migrations.
-- Les enums Prisma sont castés en text : nao_ro n'a pas USAGE sur `coop`, et
-- un LLM n'a pas à connaître les types.
--
-- GRANTS nao_ro encadrés par un test d'existence du rôle (no-op en CI).
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

-- 1. MIN : documents de feuille de route (grant direct) ------------------------
COMMENT ON TABLE min.feuille_de_route_document IS
  'Documents (PDF) deposes sur une feuille de route (feuille_de_route_id -> '
  'min.feuille_de_route). nom = nom du fichier, chemin = cle de stockage. '
  'Suppression logique : suppression non nul. editeur_utilisateur_id -> '
  'llm.utilisateur.id.';

-- 2. MIN : journal des transferts de membre ---------------------------------
-- par_utilisateur = sso_id (uuid ProConnect) de l'utilisateur MIN : clé
-- nominative (llm.cles_pii), remplacée par l'id de llm.utilisateur.
DROP VIEW IF EXISTS llm.membre_transfert_log;
CREATE VIEW llm.membre_transfert_log
  WITH (security_invoker = false) AS
SELECT
    t.id,
    t.membre_id,
    t.structure_source_id,
    t.structure_cible_id,
    t.utilisateurs_deplaces,
    t.contacts_deplaces,
    t.contacts_supprimes,
    u.id AS par_utilisateur_id,
    t.transfere_le
FROM min.membre_transfert_log t
LEFT JOIN min.utilisateur u ON u.sso_id = t.par_utilisateur;

COMMENT ON VIEW llm.membre_transfert_log IS
  'Journal des transferts d''un membre de gouvernance (membre_id -> llm.membre) '
  'd''une structure administrative source vers une cible (-> '
  'llm.structure_administrative), avec le nombre d''utilisateurs et de contacts '
  'deplaces. par_utilisateur_id -> llm.utilisateur.id (identite masquee).';

-- 3-8. Coop : vues curées -----------------------------------------------------
-- Bloc défensif (doctrine V108/V142/V144) : le schéma coop appartient à la
-- Coop (Prisma). Il n'existe pas sur une base neuve (CI test_migration) et
-- n'est que PARTIELLEMENT répliqué sur certaines bases (dev, 05/10/2026 : tables
-- manquantes ET colonnes manquantes sur les tables présentes, réplique ancienne).
-- Chaque vue est donc créée dans son propre bloc : table ou colonne absente →
-- vue ignorée avec un NOTICE, la migration continue. Sur la base cible (réplique
-- complète) les 23 vues sont créées.
DO $coop$
BEGIN
  IF to_regclass('coop.users') IS NULL THEN
    RAISE NOTICE 'Schéma coop absent (CI/base neuve) : vues llm.coop_* ignorées.';
    RETURN;
  END IF;

-- 3. Coop : comptes et profils -----------------------------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_users
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_users
    WITH (security_invoker = false) AS
  SELECT
      id,
      role::text AS role,
      email_verified,
      is_fixture,
      created,
      updated,
      deleted,
      last_login,
      last_seen,
      profil_inscription::text AS profil_inscription,
      structure_employeuse_renseignee,
      lieux_activite_renseignes,
      inscription_validee,
      acceptation_cgu,
      has_seen_onboarding,
      onboarding_status::text AS onboarding_status,
      donnees_conseiller_numerique_v1_importees,
      donnees_coordinateur_conseiller_numerique_v1_importees,
      v1_imported,
      imported_lieux_from_dataspace,
      timezone,
      siret
  FROM coop.users
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_users IS
    'Comptes de la Coop de la mediation numerique, identite masquee (ni nom, ni '
    'courriel, ni telephone). llm.personne.coop_id = cet id. Un compte a un profil '
    'mediateur (llm.coop_mediateurs.user_id) et/ou coordinateur '
    '(llm.coop_coordinateurs.user_id). role : admin | user. Suppression logique : '
    'deleted. Parcours d''inscription : profil_inscription, inscription_validee, '
    'structure_employeuse_renseignee, lieux_activite_renseignes, onboarding_status.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_users ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_mediateurs
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_mediateurs
    WITH (security_invoker = false) AS
  SELECT * FROM coop.mediateurs
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_mediateurs IS
    'Profil mediateur d''un compte Coop (user_id -> llm.coop_users). Compteurs '
    'd''activites, de beneficiaires et d''accompagnements ; is_visible = accepte '
    'd''apparaitre sur la cartographie nationale. Cle des activites '
    '(llm.coop_activites.mediateur_id) et des lieux d''activite '
    '(llm.coop_mediateurs_en_activite).'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_mediateurs ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_coordinateurs
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_coordinateurs
    WITH (security_invoker = false) AS
  SELECT * FROM coop.coordinateurs
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_coordinateurs IS
    'Profil coordinateur d''un compte Coop (user_id -> llm.coop_users). Equipe : '
    'llm.coop_mediateurs_coordonnes (coordinateur_id).'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_coordinateurs ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_employes_structures
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_employes_structures
    WITH (security_invoker = false) AS
  SELECT * FROM coop.employes_structures
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_employes_structures IS
    'Emploi declare dans la Coop : user_id (-> llm.coop_users) travaille pour '
    'structure_id (-> llm.coop_structure_administrative) ; structure_main_id = la '
    'structure canonique de l''entrepot (-> llm.structure_administrative). '
    'debut_emploi / fin_emploi ; suppression logique : suppression non nul.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_employes_structures ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_mediateurs_en_activite
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_mediateurs_en_activite
    WITH (security_invoker = false) AS
  SELECT * FROM coop.mediateurs_en_activite
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_mediateurs_en_activite IS
    'Lieux d''activite declares par un mediateur : mediateur_id -> '
    'llm.coop_mediateurs, structure_id -> llm.coop_lieu_inclusion (un LIEU, malgre '
    'le nom). debut_activite / fin_activite ; suppression logique : suppression.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_mediateurs_en_activite ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_mediateurs_coordonnes
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_mediateurs_coordonnes
    WITH (security_invoker = false) AS
  SELECT * FROM coop.mediateurs_coordonnes
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_mediateurs_coordonnes IS
    'Equipes : quel coordinateur (-> llm.coop_coordinateurs) suit quel mediateur '
    '(-> llm.coop_mediateurs). Suppression logique : suppression non nul.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_mediateurs_coordonnes ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_invitations_equipes
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_invitations_equipes
    WITH (security_invoker = false) AS
  SELECT
      coordinateur_id,
      mediateur_id,
      creation,
      acceptee,
      refusee,
      renvoyee
  FROM coop.invitations_equipes
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_invitations_equipes IS
    'Invitations d''un coordinateur a rejoindre son equipe. Le courriel invite est '
    'retire ; mediateur_id est NULL tant que l''invite n''a pas de compte. '
    'acceptee / refusee / renvoyee = dates.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_invitations_equipes ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_partage_statistiques
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_partage_statistiques
    WITH (security_invoker = false) AS
  SELECT * FROM coop.partage_statistiques
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_partage_statistiques IS
    'Autorisation donnee par un mediateur a un coordinateur de voir ses '
    'statistiques (deleted = retiree).'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_partage_statistiques ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

-- 4. Coop : structures et lieux ----------------------------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_structure_administrative
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_structure_administrative
    WITH (security_invoker = false) AS
  SELECT
      id,
      siret,
      rna,
      denomination,
      synchronisation_siret,
      nom,
      adresse,
      commune,
      code_postal,
      code_insee,
      llm.masquer_coordonnees(complement_adresse) AS complement_adresse,
      source,
      creation,
      modification,
      suppression
  FROM coop.structure_administrative
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_structure_administrative IS
    'Structures employeuses cote Coop (siret). Le referent nomme (nom, courriel, '
    'telephone) est retire. Entite canonique de l''entrepot : '
    'llm.structure_administrative.structure_coop_id = cet id. Suppression logique : '
    'suppression non nul.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_structure_administrative ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_lieu_inclusion
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_lieu_inclusion
    WITH (security_invoker = false) AS
  SELECT
      id,
      creation,
      modification,
      suppression,
      llm.masquer_coordonnees(nom)                AS nom,
      llm.masquer_coordonnees(nom_usage)          AS nom_usage,
      adresse,
      commune,
      code_postal,
      code_insee,
      llm.masquer_coordonnees(complement_adresse) AS complement_adresse,
      latitude,
      longitude,
      siret,
      rna,
      visible_pour_cartographie_nationale,
      site_web,
      telephone,
      fiche_acces_libre,
      llm.masquer_coordonnees(horaires)           AS horaires,
      llm.masquer_coordonnees(prise_rdv)          AS prise_rdv,
      structure_parente,
      typologies::text[]                      AS typologies,
      services::text[]                        AS services,
      publics_specifiquement_adresses::text[] AS publics_specifiquement_adresses,
      prise_en_charge_specifique::text[]      AS prise_en_charge_specifique,
      frais_a_charge::text[]                  AS frais_a_charge,
      dispositif_programmes_nationaux::text[] AS dispositif_programmes_nationaux,
      formations_labels::text[]               AS formations_labels,
      autres_formations_labels,
      itinerance::text[]                      AS itinerance,
      modalites_acces::text[]                 AS modalites_acces,
      modalites_accompagnement::text[]        AS modalites_accompagnement,
      v1_imported,
      v1_structure_id,
      v1_permanence_id,
      activites_count,
      ban_id,
      creation_par_id,
      derniere_modification_par_id,
      suppression_par_id,
      derniere_modification_source,
      synchronisation_siret
  FROM coop.lieu_inclusion
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_lieu_inclusion IS
    'Lieux d''activite cote Coop. Entite canonique de l''entrepot : '
    'llm.lieu_inclusion.structure_coop_id = cet id. Referent nomme, courriels et '
    'descriptifs libres retires ; site_web et telephone = coordonnees d''organisation. '
    'creation_par_id / derniere_modification_par_id / suppression_par_id -> '
    'llm.coop_users.id. Suppression logique : suppression non nul.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_lieu_inclusion ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

-- 5. Coop : activités, bénéficiaires, accompagnements ------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_activites
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_activites
    WITH (security_invoker = false) AS
  SELECT
      id,
      type::text AS type,
      mediateur_id,
      date,
      duree,
      structure_id,
      structure_employeuse_id,
      structure_employeuse_main_id,
      lieu_code_postal,
      lieu_commune,
      lieu_code_insee,
      type_lieu::text AS type_lieu,
      autonomie::text AS autonomie,
      structure_de_redirection::text AS structure_de_redirection,
      oriente_vers_structure,
      materiel::text[] AS materiel,
      thematiques::text[] AS thematiques,
      llm.masquer_coordonnees(titre_atelier) AS titre_atelier,
      niveau::text AS niveau,
      accompagnements_count,
      rdv_id,
      rdv_service_public_id,
      v1_cra_id,
      v1_cra_id_pg,
      v1_permanence_id,
      v1_structure_id,
      creation,
      modification,
      suppression
  FROM coop.activites
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_activites IS
    'Activites declarees par les mediateurs (type individuel | collectif | '
    'demarche). mediateur_id -> llm.coop_mediateurs ; structure_id -> '
    'llm.coop_lieu_inclusion (le LIEU de l''activite, NULL si a distance / a '
    'domicile) ; structure_employeuse_main_id -> llm.structure_administrative. '
    'Beneficiaires : llm.coop_accompagnements (activite_id). Textes libres (notes, '
    'precisions de demarche) retires. Plusieurs millions de lignes : toujours '
    'agreger ou filtrer par date. Pour un agregat deja rapproche de l''entrepot, '
    'preferer llm.activites_coop.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_activites ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_accompagnements
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_accompagnements
    WITH (security_invoker = false) AS
  SELECT * FROM coop.accompagnements
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_accompagnements IS
    'Liaison activite (activite_id -> llm.coop_activites) x beneficiaire '
    '(beneficiaire_id -> llm.coop_beneficiaires). premier_accompagnement = premiere '
    'fois que ce beneficiaire est accompagne. Plusieurs millions de lignes.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_accompagnements ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_beneficiaires
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_beneficiaires
    WITH (security_invoker = false) AS
  SELECT
      id,
      mediateur_id,
      anonyme,
      "attributionsAleatoires" AS attributions_aleatoires,
      pas_de_telephone,
      commune,
      commune_code_postal,
      commune_code_insee,
      genre::text AS genre,
      tranche_age::text AS tranche_age,
      statut_social::text AS statut_social,
      accompagnements_count,
      import,
      v1_imported,
      fusion_vers_id,
      creation,
      modification,
      suppression
  FROM coop.beneficiaires
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_beneficiaires IS
    'Beneficiaires des accompagnements, identite retiree (ni nom, ni coordonnees, '
    'ni annee de naissance) : ne restent que genre, tranche d''age, statut social '
    'et commune. anonyme = fiche sans identite saisie ; fusion_vers_id = doublon '
    'fusionne dans un autre beneficiaire. Ne jamais tenter de ré-identifier.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_beneficiaires ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

-- 6. Coop : coordination et tags ---------------------------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_activite_coordination
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_activite_coordination
    WITH (security_invoker = false) AS
  SELECT
      id,
      type::text AS type,
      coordinateur_id,
      llm.masquer_coordonnees(nom) AS nom,
      date,
      duree,
      echelon_territorial::text AS echelon_territorial,
      mediateurs,
      structures,
      autres_acteurs,
      type_animation::text AS type_animation,
      llm.masquer_coordonnees(type_animation_autre) AS type_animation_autre,
      initiative::text AS initiative,
      thematiques_animation::text[] AS thematiques_animation,
      llm.masquer_coordonnees(thematique_animation_autre) AS thematique_animation_autre,
      participants,
      type_evenement::text AS type_evenement,
      llm.masquer_coordonnees(type_evenement_autre) AS type_evenement_autre,
      organisateurs::text[] AS organisateurs,
      llm.masquer_coordonnees(organisateur_autre) AS organisateur_autre,
      nature_partenariat::text[] AS nature_partenariat,
      llm.masquer_coordonnees(nature_partenariat_autre) AS nature_partenariat_autre,
      llm.purger_pii(structures_partenaires) AS structures_partenaires,
      creation,
      modification,
      suppression
  FROM coop.activite_coordination
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_activite_coordination IS
    'Activites des coordinateurs (coordinateur_id -> llm.coop_coordinateurs) : '
    'animation, evenement, partenariat. mediateurs / structures / participants = '
    'nombres. Notes libres retirees, champs « autre » masques.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_activite_coordination ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_tags
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_tags
    WITH (security_invoker = false) AS
  SELECT
      id,
      llm.masquer_coordonnees(nom) AS nom,
      llm.masquer_coordonnees(description) AS description,
      departement,
      mediateur_id,
      coordinateur_id,
      equipe,
      creation,
      modification,
      suppression
  FROM coop.tags
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_tags IS
    'Etiquettes libres creees par un mediateur ou un coordinateur pour classer '
    'leurs activites (llm.coop_activite_tags, llm.coop_activite_coordination_tags). '
    'equipe = partagee avec l''equipe.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_tags ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_activite_tags
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_activite_tags
    WITH (security_invoker = false) AS
  SELECT * FROM coop.activite_tags
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_activite_tags ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_activite_coordination_tags
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_activite_coordination_tags
    WITH (security_invoker = false) AS
  SELECT * FROM coop.activite_coordination_tags
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_activite_coordination_tags ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

-- 7. Coop : historique v1 Conseiller numérique --------------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_cras_conseiller_numerique_v1
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_cras_conseiller_numerique_v1
    WITH (security_invoker = false) AS
  SELECT
      id,
      imported_at,
      v1_conseiller_numerique_id,
      canal,
      activite,
      nb_participants,
      nb_participants_recurrents,
      age_moins_12_ans,
      age_de_12_a_18_ans,
      age_de_18_a_35_ans,
      age_de_35_a_60_ans,
      age_plus_60_ans,
      statut_etudiant,
      statut_sans_emploi,
      statut_en_emploi,
      statut_retraite,
      statut_heterogene,
      themes,
      sous_themes_sante,
      sous_themes_accompagner,
      sous_themes_equipement_informatique,
      sous_themes_traitement_texte,
      duree,
      duree_minutes,
      accompagnement_individuel,
      accompagnement_atelier,
      accompagnement_redirection,
      code_postal,
      nom_commune,
      code_commune,
      date_accompagnement,
      structure_id,
      structure_id_pg,
      structure_type,
      structure_statut,
      structure_nom,
      structure_siret,
      structure_code_postal,
      structure_nom_commune,
      structure_code_commune,
      structure_code_departement,
      structure_code_region,
      permanence_id,
      permanence_structure_id,
      permanence_structure_id_pg,
      permanence_nom_enseigne,
      permanence_adresse,
      permanence_code_postal,
      permanence_nom_commune,
      permanence_code_commune,
      permanence_latitude,
      permanence_longitude,
      permanence_siret,
      permanence_site_web,
      permanence_est_structure,
      permanence_structure_nom,
      permanence_structure_siret,
      permanence_structure_statut,
      permanence_structure_type,
      permanence_structure_code_postal,
      permanence_structure_nom_commune,
      permanence_structure_code_commune,
      permanence_structure_code_departement,
      permanence_structure_code_region,
      repair_statut_migrated_at,
      created_at,
      updated_at
  FROM coop.cras_conseiller_numerique_v1
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_cras_conseiller_numerique_v1 IS
    'Comptes rendus d''activite de l''ancienne plateforme Conseiller numerique '
    '(v1, avant la Coop), importes a plat : une ligne par CRA avec les comptages '
    'par age et statut, la structure et la permanence. v1_conseiller_numerique_id = '
    'identifiant v1 du conseiller (llm.personne.conseiller_numerique_id). Annotation '
    'libre, courriel et telephone de permanence retires. Plusieurs millions de '
    'lignes.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_cras_conseiller_numerique_v1 ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

-- 8. Coop : RDV Service Public ----------------------------------------------
  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_rdv_organisations
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_rdv_organisations
    WITH (security_invoker = false) AS
  SELECT id,
         name,
         -- adresse generique conservee ; adresse de forme prenom.nom@ retiree
         CASE WHEN email ~* '^[a-z-]+\.[a-z-]+@' THEN NULL ELSE email END AS email,
         verticale,
         synced_at
  FROM coop.rdv_organisations
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_rdv_organisations IS
    'Organisations RDV Service Public liees a des comptes Coop. Courriel generique '
    'conserve, telephone retire.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_rdv_organisations ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_rdv_lieux
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_rdv_lieux
    WITH (security_invoker = false) AS
  SELECT id, name, address, phone_number, organisation_id, single_use, synced_at
  FROM coop.rdv_lieux
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_rdv_lieux ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_rdv_motifs
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_rdv_motifs
    WITH (security_invoker = false) AS
  SELECT id, name, organisation_id, collectif, follow_up, location_type,
         motif_category_id
  FROM coop.rdv_motifs
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_rdv_motifs ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_rdvs
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_rdvs
    WITH (security_invoker = false) AS
  SELECT
      id,
      uuid,
      organisation_id,
      motif_id,
      lieu_id,
      rdv_account_id,
      llm.masquer_coordonnees(name) AS name,
      address,
      collectif,
      status::text AS status,
      starts_at,
      ends_at,
      duration_in_min,
      max_participants_count,
      users_count,
      created_by::text AS created_by,
      created_by_type::text AS created_by_type,
      created_by_id,
      cancelled_at,
      cra_declined,
      created_at,
      synced_at
  FROM coop.rdvs
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_rdvs IS
    'Rendez-vous synchronises depuis RDV Service Public (organisation_id, '
    'motif_id, lieu_id -> llm.coop_rdv_*). Une activite Coop peut en decouler '
    '(llm.coop_activites.rdv_id). Charge utile brute et contexte retires ; les '
    'usagers RDV ne sont pas exposes.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_rdvs ignorée (réplique coop incomplète) : %', SQLERRM;
  END;

  EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_rdv_participations
  $v$;
  BEGIN
    EXECUTE $v$
  CREATE VIEW llm.coop_rdv_participations
    WITH (security_invoker = false) AS
  SELECT id, rdv_id, status, created_by::text AS created_by,
         created_by_type::text AS created_by_type, created_by_id,
         created_by_agent_prescripteur, send_lifecycle_notifications,
         send_reminder_notification, synced_at
  FROM coop.rdv_participations
    $v$;

    EXECUTE $v$
  COMMENT ON VIEW llm.coop_rdv_participations IS
    'Participations a un rendez-vous (rdv_id -> llm.coop_rdvs) : statut de '
    'presence. L''usager participant n''est pas expose.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_rdv_participations ignorée (réplique coop incomplète) : %', SQLERRM;
  END;
END
$coop$;

-- 9. Droits nao_ro -----------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON min.feuille_de_route_document TO nao_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA llm TO nao_ro;
  END IF;
END
$$;
