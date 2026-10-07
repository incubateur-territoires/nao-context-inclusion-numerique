-- ============================================================
-- V179 – Schéma `llm` : tranche d'âge dérivée des bénéficiaires Coop et
--        labellisation Conum, pour reconstruire le tableau de bord MIN
-- ============================================================
-- CONTEXTE (#1591, suite de V178) :
-- Inventaire des 70 indicateurs du tableau de bord et de la page statistiques
-- de MIN (06/10/2026) : 68 sont reconstructibles avec le périmètre nao_ro.
-- Deux manques :
--   1. La répartition par tranche d'âge des bénéficiaires (page statistiques)
--      est DÉRIVÉE de coop.beneficiaires.annee_naissance quand l'année est
--      plausible, sinon de la tranche saisie (même règle que l'API Coop). V178 a
--      retiré annee_naissance de llm.coop_beneficiaires (commune + genre + année
--      = ré-identifiable). On expose la tranche dérivée, pas l'année : un
--      intervalle de 5 à 20 ans n'identifie personne.
--   2. main.conum_labellisation (bandeau « structure labellisée ») n'était pas
--      ouverte à nao_ro ; elle ne porte qu'un id de structure, un id
--      d'utilisateur MIN (identité masquée par llm.utilisateur) et une date.
--
-- GRANTS nao_ro encadrés par un test d'existence du rôle (no-op en CI). Bloc
-- défensif sur le schéma coop (absent en CI, partiel sur dev) comme V178.
-- Pas de NOTIFY pgrst : on ne touche pas au schéma api.*
-- ============================================================

-- 1. llm.coop_beneficiaires : tranche_age_derivee -----------------------------
DO $coop$
BEGIN
  BEGIN
    EXECUTE $v$
DROP VIEW IF EXISTS llm.coop_beneficiaires
    $v$;
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
    COALESCE(
      CASE
        WHEN annee_naissance IS NULL
          OR annee_naissance < 1900
          OR annee_naissance > EXTRACT(YEAR FROM CURRENT_DATE) THEN NULL
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 12 THEN 'moins_de_douze'
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 18 THEN 'douze_dix_huit'
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 25 THEN 'dix_huit_vingt_quatre'
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 40 THEN 'vingt_cinq_trente_neuf'
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 60 THEN 'quarante_cinquante_neuf'
        WHEN EXTRACT(YEAR FROM CURRENT_DATE) - annee_naissance < 70 THEN 'soixante_soixante_neuf'
        ELSE 'soixante_dix_plus'
      END,
      tranche_age::text) AS tranche_age_derivee,
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
  'et commune. tranche_age = tranche saisie ; tranche_age_derivee = tranche '
  'calculee depuis l''annee de naissance quand elle est plausible, sinon la '
  'tranche saisie — c''est celle qu''affichent MIN et la Coop (valeurs : '
  'moins_de_douze, douze_dix_huit, dix_huit_vingt_quatre, vingt_cinq_trente_neuf, '
  'quarante_cinquante_neuf, soixante_soixante_neuf, soixante_dix_plus). anonyme = '
  'fiche sans identite saisie ; fusion_vers_id = doublon fusionne dans un autre '
  'beneficiaire. Ne jamais tenter de re-identifier.'
    $v$;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    RAISE NOTICE 'llm.coop_beneficiaires ignorée (réplique coop incomplète) : %', SQLERRM;
  END;
END
$coop$;

-- 2. main.conum_labellisation ---------------------------------------------------
COMMENT ON TABLE main.conum_labellisation IS
  'Attestations de labellisation Conseiller numerique d''une structure '
  '(structure_id -> llm.structure_administrative), deposees depuis MIN '
  '(utilisateur_id -> llm.utilisateur, identite masquee). Une structure est '
  'labellisee si elle a au moins une ligne.';

-- 3. Droits nao_ro --------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nao_ro') THEN
    GRANT SELECT ON ALL TABLES IN SCHEMA llm TO nao_ro;
    GRANT SELECT ON main.conum_labellisation TO nao_ro;
  END IF;
END
$$;
