-- ============================================================
-- V173 – Schéma `llm` : aligner les droits de nao_ro sur ce qu'un outil de
--        support doit voir (Tier 2 pseudonymisé, lieux, gouvernance)
-- ============================================================
-- CONTEXTE (#1591, suite de V102/V103/V172) :
-- L'outil LLM (Nao, rôle read-only nao_ro) doit servir le support : « que
-- s'est-il passé pour ce membre / ce lieu / ce poste ? ». Défauts constatés le
-- 24/09/2026 sur une session réelle puis par un audit colonne à colonne de tout
-- ce que nao_ro peut lire (497 colonnes, 182 colonnes texte scannées) :
--   1. Le commentaire posé par V172 sur llm.structure désigne main.structure ;
--      la vue lit min.structure (V102 §6). Mauvaise cible, mauvaise raison.
--   2. main.lieu_inclusion était en accès direct depuis V102 au motif que son
--      `contact` ne porte que des coordonnées d'organisation. Relevé en base :
--      contact->'courriels' contient `mail_gestionnaire` (200 lignes),
--      `referent_hierarchique` (182) et `mail_2` (51) — des adresses de
--      personnes, déjà listées dans llm.cles_pii(). Un nom de lieu et un champ
--      horaires portent aussi nom + mobile d'un agent.
--   3. min.gouvernance était en accès direct avec `note_privee` (jsonb) : une
--      note explicitement privée du gestionnaire départemental.
--   4. main.adresse.nom_voie : 56 lignes ne sont pas un nom de voie mais un
--      bloc d'adresse brut collé à l'import, avec civilité, nom complet et
--      parfois courriel d'un agent (« Mme X / x@… »). Table pivot jointe par
--      toutes les structures et tous les lieux.
--   5. main.personne.profession_ac : 8 lignes portent un courriel personnel
--      saisi à la place d'un intitulé de métier — dans la vue llm.personne
--      censée être sans nominatif.
--   6. main.activites_coop.precisions_demarche : texte libre saisi par les
--      médiateurs (4 M de lignes) ; noms de travailleurs sociaux et de
--      bénéficiaires relevés sur échantillon.
--   7. main.lieu_appariement.decide_par : courriel du décideur humain.
--
-- STRATÉGIE : la base est la seule couche de protection (la configuration Nao
-- ne fait qu'en refléter le périmètre). Même patron que V102/V172 : vues curées
-- en security_invoker = false, révocation de l'accès direct.
--   * llm.lieu_inclusion : registre sans `contact` (éclaté en site_web /
--     telephone / email d'organisation, cf. carto nationale publique), sans
--     `presentation_resume` / `presentation_detail` (texte libre, règle V172)
--     ni `import_warnings` (technique) ; nom, nom_usage, complement_adresse,
--     horaires et prise_rdv passés par llm.masquer_coordonnees(). `edited_by`
--     conservé : libellé de source (carto, coop, min…), pas une identité.
--   * llm.gouvernance : sans `note_privee` ni `editeur_note_privee_id` ;
--     `note_de_contexte` (HTML public aux membres de la gouvernance) conservée
--     et masquée (3 notes sur 101 contenaient un courriel, 2 un téléphone).
--     ~13 notes citent un référent par son nom en clair : conservation validée
--     par le PO le 24/09/2026 (texte destiné aux membres de la gouvernance).
--   * llm.adresse : main.adresse avec nom_voie mis à NULL quand il n'en est
--     pas un (longueur > 60, civilité, courriel).
--   * llm.personne / llm.personne_enrichie : profession_ac mis à NULL quand
--     il contient un courriel.
--   * llm.activites_coop : main.activites_coop sans `precisions_demarche`.
--   * llm.lieu_appariement : main.lieu_appariement sans `decide_par`.
--   * Les autres tables « Tier 2 » (poste, contrat, formation, affectations,
--     subvention, min.action…) restent en accès direct : identifiants
--     techniques sans nominatif, identités masquées par llm.personne /
--     llm.membre. Elles reçoivent un COMMENT ON pour que l'outil sache s'en
--     servir (relkind-agnostique : personne_affectations_lieu est une vue en
--     base réelle et une table en CI).
--   * min._prisma_migrations : révoquée (bruit technique).
--
-- GRANT/REVOKE nao_ro encadrés par un test d'existence du rôle (no-op en CI).
-- Les REVOKE sur min.* suivent le patron de V102 (ACL vérifiées après coup).
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

-- 1. Commentaire de llm.structure (erreur de V172) ---------------------------
COMMENT ON VIEW llm.structure IS
  'min.structure — table DEPRECIEE de l''application MIN (ancien referentiel de '
  'structures, avant la bascule sur main.structure_administrative). Ne plus s''en '
  'servir pour repondre : llm.membre.structure_id et llm.utilisateur.structure_id '
  'pointent llm.structure_administrative (main.structure_administrative), pas '
  'cette table. Seuls old_structure_id (llm.membre, llm.utilisateur) y renvoient '
  'encore, a titre historique.';

-- 2. Masquage des coordonnées dans un texte libre ----------------------------
-- Courriels et numéros de téléphone français (0X XX XX XX XX, +33 X XX XX XX XX,
-- avec ou sans séparateurs). Ne prétend pas retirer les noms propres : à
-- n'utiliser que sur un texte déjà destiné à un public large.
CREATE OR REPLACE FUNCTION llm.masquer_coordonnees(t text)
  RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT regexp_replace(
           regexp_replace(t,
             '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
             '[courriel masqué]', 'g'),
           '(\+33[ .-]?[1-9]|0[1-9])([ .-]?[0-9]{2}){4}',
           '[téléphone masqué]', 'g')
$$;

COMMENT ON FUNCTION llm.masquer_coordonnees(text) IS
  'Remplace courriels et numeros de telephone francais par un libelle neutre '
  'dans un texte libre. Utilisee par les vues llm.gouvernance et '
  'llm.lieu_inclusion.';

-- 3. llm.lieu_inclusion ------------------------------------------------------
DROP VIEW IF EXISTS llm.lieu_inclusion;
CREATE VIEW llm.lieu_inclusion
  WITH (security_invoker = false) AS
SELECT
    id,
    old_main_structure_id,
    llm.masquer_coordonnees(nom)                AS nom,
    llm.masquer_coordonnees(nom_usage)          AS nom_usage,
    adresse_id,
    llm.masquer_coordonnees(complement_adresse) AS complement_adresse,
    structure_cartographie_nationale_id,
    structure_coop_id,
    siret_a_l_enrichissement,
    visible_pour_cartographie_nationale,
    fiche_acces_libre,
    llm.masquer_coordonnees(horaires)           AS horaires,
    llm.masquer_coordonnees(prise_rdv)          AS prise_rdv,
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
    contact ->> 'site_web'              AS contact_site_web,
    contact ->> 'telephone'             AS contact_telephone,
    contact -> 'courriels' ->> 'email'  AS contact_email,
    source,
    edited_by,
    created_at,
    updated_at,
    updated_at_carto,
    updated_at_coop,
    updated_at_min,
    deleted_at
FROM main.lieu_inclusion;

COMMENT ON VIEW llm.lieu_inclusion IS
  'Lieux d''inclusion numerique (registre unifie coop + cartographie nationale, '
  'V153). Un lieu = un endroit ou l''on accueille du public. Il n''existe PLUS '
  'de lien direct lieu <-> structure administrative (table d''association '
  'supprimee en V123, #1711) : le rapprochement passe par les personnes '
  '(main.personne_affectations_lieu -> personne_id -> '
  'main.personne_affectations_emploi -> structure_administrative_id) ou par '
  'siret_a_l_enrichissement (SIRET declare a l''import, non garanti). '
  'structure_cartographie_nationale_id = id sur la carto nationale ; '
  'structure_coop_id = id de la structure cote Coop. Coordonnees d''ORGANISATION '
  'uniquement (site web, telephone, courriel generique du lieu) ; les adresses '
  'de gestionnaire ou de referent sont retirees. Suppression logique : '
  'deleted_at. Attention : les id de cette vue et ceux de '
  'llm.structure_administrative se recouvrent et ne designent pas la meme chose. '
  'edited_by = derniere source ayant ecrit la ligne (carto, coop, min, '
  'app_python…), pas une personne. Adresse : joindre llm.adresse sur adresse_id. '
  'Personnes qui y travaillent : main.personne_affectations_lieu (lieu_id, '
  'personne_id, est_active). Activites : llm.activites_coop (lieu_id).';

-- 4. llm.gouvernance ---------------------------------------------------------
DROP VIEW IF EXISTS llm.gouvernance;
CREATE VIEW llm.gouvernance
  WITH (security_invoker = false) AS
SELECT
    departement_code,
    llm.masquer_coordonnees(note_de_contexte) AS note_de_contexte,
    derniere_edition_note_de_contexte,
    editeur_note_de_contexte_id
FROM min.gouvernance;

COMMENT ON VIEW llm.gouvernance IS
  'Gouvernance departementale de l''inclusion numerique (application MIN) : une '
  'ligne par departement. note_de_contexte = texte HTML de presentation de la '
  'gouvernance, courriels et telephones masques. La note privee du gestionnaire '
  'n''est pas exposee. editeur_note_de_contexte_id se joint a llm.utilisateur.id. '
  'Membres : llm.membre (gouvernance_departement_code). Feuilles de route, '
  'actions, comites, demandes de subvention : tables min.* du meme nom.';

-- 5. llm.lieu_appariement ----------------------------------------------------
DROP VIEW IF EXISTS llm.lieu_appariement;
CREATE VIEW llm.lieu_appariement
  WITH (security_invoker = false) AS
SELECT
    id,
    carto_segment,
    lieu_id,
    carto_record_id,
    source,
    methode,
    statut,
    score_nom,
    score_adresse,
    score_distance,
    score_global,
    distance_m,
    carto_nom,
    carto_adresse,
    carto_commune,
    premiere_detection,
    derniere_detection,
    decide_le
FROM main.lieu_appariement;

COMMENT ON VIEW llm.lieu_appariement IS
  'Memoire du rapprochement entre un lieu du registre (lieu_id -> '
  'llm.lieu_inclusion) et une fiche de la cartographie nationale '
  '(carto_record_id, carto_segment). methode : segment_coop (preuve par fusion) '
  '| similarite (candidat score). statut : auto | a_valider | valide | rejete ; '
  'valide et rejete sont des decisions humaines (decide_le), jamais ecrasees. '
  'L''identite du decideur n''est pas exposee.';

-- 6. llm.adresse -------------------------------------------------------------
-- nom_voie n'est pas fiable : 56 lignes portent un bloc d'adresse brut (nom
-- complet, civilité, courriel). Un vrai nom de voie ne dépasse pas 60
-- caractères en base et ne contient ni civilité ni « @ ».
DROP VIEW IF EXISTS llm.adresse;
CREATE VIEW llm.adresse
  WITH (security_invoker = false) AS
SELECT
    id,
    geom,
    clef_interop,
    code_ban,
    code_postal,
    code_insee,
    nom_commune,
    CASE
      WHEN length(nom_voie) > 60
        OR nom_voie ~ '@'
        OR nom_voie ~* '\m(mme|mr|monsieur|madame)\M'
      THEN NULL
      ELSE nom_voie
    END AS nom_voie,
    repetition,
    numero_voie,
    departement,
    created_at,
    updated_at
FROM main.adresse;

COMMENT ON VIEW llm.adresse IS
  'Adresses normalisees (BAN) partagees par les structures administratives et '
  'les lieux d''inclusion (adresse_id). Adresse d''organisation, donnee publique. '
  'code_insee / nom_commune / code_postal / departement pour les agregats '
  'territoriaux ; geom (PostGIS) pour les distances. numero_voie est un entier, '
  'repetition porte bis/ter. nom_voie est NULL quand la valeur importee n''etait '
  'pas un nom de voie.';

-- 7. llm.personne / llm.personne_enrichie : profession_ac assaini -----------
-- Mêmes colonnes et même ordre que V102 / V103 (CREATE OR REPLACE).
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
    CASE WHEN profession_ac ~ '@' THEN NULL ELSE profession_ac END AS profession_ac,
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
    CASE WHEN profession_ac ~ '@' THEN NULL ELSE profession_ac END AS profession_ac,
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

-- 8. llm.activites_coop ------------------------------------------------------
DROP VIEW IF EXISTS llm.activites_coop;
CREATE VIEW llm.activites_coop
  WITH (security_invoker = false) AS
SELECT
    coop_id,
    lieu_id,
    personne_id,
    type,
    date,
    duree,
    lieu_code_insee,
    type_lieu,
    autonomie,
    structure_de_redirection,
    oriente_vers_structure,
    degre_de_finalisation_demarche,
    titre_atelier,
    niveau_atelier,
    accompagnements,
    thematiques,
    materiels,
    thematiques_demarche_administrative,
    created_at,
    updated_at,
    periode,
    created_at_coop,
    updated_at_coop,
    beneficiaires
FROM main.activites_coop;

COMMENT ON VIEW llm.activites_coop IS
  'Activites d''accompagnement declarees dans la Coop de la mediation numerique '
  '(sur main.activites_coop, V144). Une ligne par activite : type individuel | '
  'collectif, date, duree (minutes), personne_id (mediateur -> llm.personne), '
  'lieu_id (-> llm.lieu_inclusion, NULL si a distance ou a domicile), '
  'lieu_code_insee, thematiques (tableau), beneficiaires (nombre). Le texte '
  'libre precisions_demarche n''est pas expose. Volumetrie : plusieurs millions '
  'de lignes — toujours agreger ou filtrer par periode.';

-- 9. Commentaires sur les tables en accès direct (support) --------------------
DO $$
DECLARE
  cible  record;
  genre  text;
BEGIN
  FOR cible IN
    SELECT * FROM (VALUES
      ('main.poste',
       'Postes Conseiller numerique (dispositif CnFS / idposte). Un poste = un '
       'financement d''ETP attribue a une structure (structure_id -> '
       'llm.structure_administrative). typologie : conum (conseiller), coordo '
       '(coordinateur), dns. etat : occupe | vacant | rendu (poste restitue par la '
       'structure, date_rendu_poste). personne_id (-> llm.personne) = titulaire '
       'courant, NULL si vacant. Subventions associees : main.subvention (poste_id). '
       'Contrats : main.contrat (structure_id, personne_id).'),
      ('main.contrat',
       'Contrats de travail des conseillers numeriques (source idposte). Une ligne par '
       'contrat : personne_id (-> llm.personne), structure_id (-> '
       'llm.structure_administrative), type (CDD, CDI, CDP = contrat de projet, PEC, '
       'NULL si inconnu), date_debut, date_fin (fin prevue) et date_rupture (fin '
       'anticipee). Contrat ACTIF = date_rupture IS NULL ; ne pas utiliser date_fin '
       'pour le determiner.'),
      ('main.contact_structure_administrative',
       'Liaison N:N entre une structure administrative et ses contacts (contact_id -> '
       'llm.contact, identite masquee : seule la fonction est visible).'),
      ('main.personne_affectations_lieu',
       'Personnes rattachees a un lieu d''inclusion (donnees coop, V151). '
       'personne_id -> llm.personne, lieu_id -> llm.lieu_inclusion, est_active = '
       'rattachement en cours. Compter des mediateurs par lieu : filtrer est_active.')
    ) AS t(objet, texte)
  LOOP
    SELECT CASE relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END
      INTO genre
    FROM pg_class WHERE oid = cible.objet::regclass;
    EXECUTE format('COMMENT ON %s %s IS %L', genre, cible.objet, cible.texte);
  END LOOP;
END
$$;

-- 10. Droits nao_ro -----------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON llm.lieu_inclusion, llm.gouvernance, llm.lieu_appariement,
                    llm.adresse, llm.activites_coop
      TO nao_ro;
    GRANT EXECUTE ON FUNCTION llm.masquer_coordonnees(text) TO nao_ro;

    REVOKE SELECT ON main.lieu_inclusion    FROM nao_ro;
    REVOKE SELECT ON main.lieu_appariement  FROM nao_ro;
    REVOKE SELECT ON main.adresse           FROM nao_ro;
    REVOKE SELECT ON main.activites_coop    FROM nao_ro;
    REVOKE SELECT ON min.gouvernance        FROM nao_ro;
    REVOKE SELECT ON min._prisma_migrations FROM nao_ro;
  END IF;
END
$$;
