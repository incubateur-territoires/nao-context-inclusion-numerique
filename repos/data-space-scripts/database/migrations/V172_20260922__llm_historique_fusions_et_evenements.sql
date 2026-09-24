-- ============================================================
-- V172 – Schéma `llm` : ouvrir l'historique (fusions + journal MIN) à nao_ro
-- ============================================================
-- CONTEXTE :
-- L'outil LLM branché en lecture seule (rôle nao_ro, cf. V102/V103, #1591) ne
-- peut pas répondre aux questions d'historique — « cette structure a disparu,
-- que lui est-il arrivé, et qui l'a fait ? ». Les objets qui portent la réponse
-- vivent dans deux schémas jamais ouverts à nao_ro :
--   * audit.structure_merge_log / audit.personne_merge_log — la SEULE trace
--     reliant deux entités fusionnées. La perdante reçoit un `deleted_at` et
--     rien, dans les tables métier, ne dit vers qui ses identifiants sont partis.
--   * source.min__evenements — le QUI et le QUAND de chaque modification faite
--     depuis l'application MIN.
-- Sans ces deux sources, nao_ro voit deux structures sans rapport dont une
-- supprimée, et conclut à tort « structure introuvable ».
--
-- STRATÉGIE : identique à V102 — AUCUN grant sur les schémas `audit` et
-- `source`. On expose des vues curées dans `llm`, en security_invoker = false :
-- elles lisent leurs tables de base avec les droits de LEUR PROPRIÉTAIRE, donc
-- nao_ro n'obtient aucun droit direct sur les journaux bruts.
--
-- PII : les instantanés JSONB de ces journaux contiennent du nominatif
--   * audit.structure_merge_log : `contact` (nom, prénom, courriels, téléphone
--     du gestionnaire), `edited_by`, `deleted_by` ;
--   * audit.personne_merge_log  : `nom`, `prenom`, `contact`, idem ;
--   * source.min__evenements    : `donnee->value->old|new` est un JSONB libre —
--     les clés `email`, `nom`, `prenom`, `telephone`, `fonction` y sont déjà
--     observées.
-- Purge clé à clé et RÉCURSIVE (llm.purger_pii), car certains payloads sont
-- imbriqués (audit.personne_merge_log.moved_identifiers = {loser:{…},
-- winner_after:{…}}). Liste noire centralisée dans llm.cles_pii() : une seule
-- source de vérité, réutilisable par les tests de non-régression.
--
-- GRANTS nao_ro : encadrés par un test d'existence du rôle (no-op en CI/test où
-- nao_ro n'existe pas ; actif en prod). Le rôle lui-même se crée HORS Flyway
-- (scripts/create_user_nao_readonly.sql).
--
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

-- 1. Liste noire des clés nominatives ---------------------------------------
-- Aligné sur les colonnes supprimées par V102/V103 (main.personne, main.contact,
-- min.utilisateur, min.membre, main.structure_administrative).
CREATE OR REPLACE FUNCTION llm.cles_pii()
  RETURNS text[]
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT ARRAY[
    'nom', 'prenom', 'email', 'email_de_contact', 'sso_email', 'sso_id',
    'telephone', 'fonction', 'contact', 'contact_technique', 'courriels',
    'mail_gestionnaire', 'referent_hierarchique',
    'edited_by', 'deleted_by', 'decide_par',
    -- Texte libre : les instantanés hérités du DAG structures-similarities-merge
    -- (table LEGACY main.structure, forme « lieu ») en contiennent, et on y a
    -- relevé des adresses de contact rédigées à la main. Organisationnelles dans
    -- les cas observés, mais rien ne garantit qu'une adresse personnelle n'y
    -- figure pas : on ne sert aucun texte libre au LLM.
    'presentation_detail', 'presentation_resume',
    -- Clé malformée relevée en base réelle le 22/09/2026 (2 occurrences dans
    -- source.min__evenements) : un nom de clé littéral « :suppression », signe
    -- d'une interpolation ratée côté MIN. Contenu non qualifié → purgée par
    -- précaution tant qu'on ne sait pas ce qu'elle transporte.
    ':suppression'
  ]
$$;

-- 2. Purge récursive d'un JSONB ---------------------------------------------
-- plpgsql (et non sql) : une fonction SQL ne peut pas se référencer elle-même
-- à la création (check_function_bodies), alors qu'un corps plpgsql n'est pas
-- résolu à ce moment-là. Objets ET tableaux imbriqués sont traversés.
CREATE OR REPLACE FUNCTION llm.purger_pii(j jsonb)
  RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
AS $$
DECLARE
  resultat jsonb;
  cle      text;
  valeur   jsonb;
BEGIN
  IF j IS NULL THEN
    RETURN NULL;
  END IF;

  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      resultat := '{}'::jsonb;
      FOR cle, valeur IN SELECT * FROM jsonb_each(j) LOOP
        CONTINUE WHEN cle = ANY (llm.cles_pii());
        resultat := resultat || jsonb_build_object(cle, llm.purger_pii(valeur));
      END LOOP;
      RETURN resultat;

    WHEN 'array' THEN
      RETURN COALESCE(
        (SELECT jsonb_agg(llm.purger_pii(element))
           FROM jsonb_array_elements(j) AS element),
        '[]'::jsonb);

    ELSE
      RETURN j;
  END CASE;
END
$$;

-- 3. audit.structure_merge_log ----------------------------------------------
CREATE OR REPLACE VIEW llm.structure_merge_log
  WITH (security_invoker = false) AS
SELECT
    id,
    merged_at,
    status,
    dag_id,
    run_id,
    task_id,
    map_index,
    try_number,
    winner_id,
    loser_id,
    similarity_score,
    similarity_threshold,
    llm.purger_pii(winner_before)    AS winner_before,
    llm.purger_pii(loser_before)     AS loser_before,
    llm.purger_pii(winner_after)     AS winner_after,
    llm.purger_pii(moved_identifiers) AS moved_identifiers,
    error_message
FROM audit.structure_merge_log;

-- 4. audit.personne_merge_log ------------------------------------------------
CREATE OR REPLACE VIEW llm.personne_merge_log
  WITH (security_invoker = false) AS
SELECT
    id,
    merged_at,
    status,
    dag_id,
    run_id,
    task_id,
    map_index,
    try_number,
    match_type,
    winner_id,
    loser_id,
    similarity_score,
    similarity_threshold,
    llm.purger_pii(winner_before)     AS winner_before,
    llm.purger_pii(loser_before)      AS loser_before,
    llm.purger_pii(winner_after)      AS winner_after,
    llm.purger_pii(moved_identifiers) AS moved_identifiers,
    error_message
FROM audit.personne_merge_log;

-- 5. source.min__evenements ---------------------------------------------------
-- `donnee` éclatée en colonnes : un LLM ne devine pas qu'entity_id est du TEXTE
-- (id numérique de structure OU id métier de membre selon source_key).
CREATE OR REPLACE VIEW llm.evenement
  WITH (security_invoker = false) AS
SELECT
    e.id,
    e.ingested_at,
    e.source_key,
    e.donnee ->> 'action'              AS action,
    e.donnee ->> 'entity_id'           AS entity_id,
    (e.donnee ->> 'user_id')::bigint   AS user_id,
    llm.purger_pii(e.donnee -> 'value' -> 'old') AS valeur_avant,
    llm.purger_pii(e.donnee -> 'value' -> 'new') AS valeur_apres
FROM source.min__evenements e;

-- 6. Droits nao_ro ------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON llm.structure_merge_log,
                    llm.personne_merge_log,
                    llm.evenement
      TO nao_ro;
    -- EXECUTE est déjà donné à PUBLIC par défaut ; explicite pour la lisibilité.
    GRANT EXECUTE ON FUNCTION llm.purger_pii(jsonb), llm.cles_pii() TO nao_ro;
  END IF;
END
$$;

-- 7. Contexte lisible par l'outil (obj_description) ---------------------------
-- Les 7 vues de V102/V103 n'avaient aucun commentaire : l'outil voyait des noms
-- nus. Sans ces descriptions, il ne peut pas deviner qu'une suppression est
-- toujours logique, ni qu'un id d'entier est ambigu entre SA et lieu.

COMMENT ON VIEW llm.structure_merge_log IS
  'Journal des fusions de structures administratives. Une ligne = une fusion : '
  'loser_id est absorbee dans winner_id, puis marquee deleted_at. SEULE trace du '
  'lien entre deux structures fusionnees (aucune colonne metier ne le porte). '
  'moved_identifiers = identifiants (siret/rna/ridet) transferes au gagnant. '
  'dag_id = ''min-ui'' avec similarity_score NULL : fusion manuelle depuis '
  'l''admin MIN ; un score et un seuil renseignes : appariement automatique. '
  'winner_before/loser_before/winner_after = instantanes avant/apres, purges des '
  'donnees nominatives.';

COMMENT ON VIEW llm.personne_merge_log IS
  'Journal des fusions de personnes. Memes regles que llm.structure_merge_log. '
  'match_type = nature de l''appariement ayant declenche la fusion. '
  'moved_identifiers imbrique {loser:{...}, winner_after:{...}} = identifiants '
  'techniques (coop_id, cn_pg_id, aidant_connect_id, conseiller_numerique_id).';

COMMENT ON VIEW llm.evenement IS
  'Journal des modifications faites depuis l''application MIN : repond au QUI et '
  'au QUAND. entity_id est du TEXTE et vaut, selon source_key, un id numerique de '
  'structure administrative OU un id metier de membre (ex. epci-200068641-31) : '
  'caster explicitement avant toute jointure. user_id se joint a '
  'llm.utilisateur.id (identite masquee : seuls role, departement_code et '
  'is_super_admin sont exposes). valeur_avant/valeur_apres ne contiennent que '
  'les colonnes reellement modifiees, purgees des donnees nominatives.';

COMMENT ON VIEW llm.structure_administrative IS
  'Structures administratives (personnes morales identifiees par SIRET). Un meme '
  'SIRET porte souvent PLUSIEURS lignes : le siege (denomination_antenne NULL) et '
  'ses antennes, et une ligne peut etre RECREEE par un import apres une fusion. '
  'Suppression logique : deleted_at non nul. Une structure absente d''une requete '
  'peut avoir ete absorbee — verifier llm.structure_merge_log des deux cotes '
  '(winner_id ET loser_id). Attention : les id de cette table et ceux de '
  'main.lieu_inclusion se recouvrent et ne designent pas la meme chose.';

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

COMMENT ON VIEW llm.personne IS
  'Personnes (mediateurs, conseillers numeriques), identite masquee (V102). '
  'Suppression logique : deleted_at. Fusions : llm.personne_merge_log.';

COMMENT ON VIEW llm.contact IS
  'Contacts, identite masquee (V102) : ne restent que la fonction, les drapeaux '
  'et les dates.';

COMMENT ON VIEW llm.structure IS
  'main.structure — table LEGACY en voie de disparition (refonte SA / lieux). '
  'Ne pas l''utiliser pour repondre : passer par llm.structure_administrative.';

COMMENT ON VIEW llm.personne_enrichie IS
  'Vue d''enrichissement des personnes, identite masquee (V103) : drapeaux '
  'd''activite et type d''accompagnateur, sans colonne nominative.';

COMMENT ON FUNCTION llm.cles_pii() IS
  'Liste noire des cles JSONB nominatives, source de verite unique pour la purge '
  'et pour les tests de non-regression RGPD.';

COMMENT ON FUNCTION llm.purger_pii(jsonb) IS
  'Retire recursivement les cles de llm.cles_pii() d''un JSONB (objets et '
  'tableaux imbriques compris). Utilisee par les vues d''historique du schema llm.';

-- 8. Note : les vues llm.* sur le schéma `min` -----------------------------
-- Les tables du schéma `min` appartiennent à min_scalingo (Prisma), pas au
-- rôle Flyway de dataspace. Comme les vues de V102 sont en
-- security_invoker = false, llm.membre / llm.utilisateur / llm.structure ne
-- fonctionnent que si le propriétaire des vues a un SELECT sur min.*.
-- Vérifié en production le 22/09/2026 : c'est le cas (sonum), ces trois vues
-- sont opérationnelles. En revanche, sur une base restaurée localement le
-- grant ne suit pas toujours et elles renvoient « permission denied » — ce
-- n'est PAS un défaut de la production, et on ne le corrige pas ici : sur une
-- copie locale, jouer manuellement
--   GRANT SELECT ON min.membre, min.utilisateur, min.structure TO sonum;
