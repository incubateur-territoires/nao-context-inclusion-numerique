-- ============================================================
-- V073 – Refonte phase 2 : peuplement initial de structure_administrative
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md, phase 2. Premier peuplement depuis
-- main.structure vers le nouveau modèle. Anciennes tables intactes.
--
-- CRITÈRE "is_admin" (= candidate à structure_administrative) :
--   - a une affectation type=structure_emploi (active OU inactive), OU
--   - est référencée par main.contrat / main.poste / main.contact_structure, OU
--   - est référencée par min.membre / min.utilisateur
-- Note : main.activites_coop n'est pas pris en compte ici. Test sur
-- dataspace_dev a montré que activites_coop.structure_id pointe parfois
-- sur des structures sans SIRET (6 143 cas), dont la sémantique n'est pas
-- clairement 'employeuse'. Les structures qui n'existent QUE pour des
-- activites_coop tomberont en 'vraies orphelines' (16 023) et seront
-- supprimées en phase 0.5.c. À reconsidérer si problème en phase 4.
-- Cf décision tranchée "Inclure les 3 769 intermédiaires" (2026-05-22).
--
-- STRATÉGIE DE FUSION (cf décisions tranchées 2026-05-22 + 2026-05-25) :
--   - DISTINCT ON (siret, nom) : 1 ligne par tuple (siret, nom).
--     Cette stratégie préserve les "antennes opérationnelles" des grands
--     réseaux qui partagent un SIRET unique mais sont sémantiquement
--     distinctes (Emmaüs Connect Évry / Saint-Quentin / Châteauroux…).
--     Cf décision 2026-05-25 : ajout de la colonne denomination_antenne
--     et UNIQUE NULLS NOT DISTINCT (siret, denomination_antenne) sur V068.
--   - ORDER BY priorité edited_by (autoritaire → moins) :
--       id-poste > aidants-connect > coop > carto > migrate >
--       update_conum > sonum > app_python > min_scalingo
--   - Tiebreaker : MAX(updated_at) DESC NULLS LAST, puis id
--   - denomination_antenne = nom legacy SI le SIRET a plusieurs noms
--     distincts dans les candidates (= réseau d'antennes), sinon NULL
--     (entité unique pour ce SIRET).
--   - Sans SIRET (139 cas) : chacune devient sa propre ligne,
--     denomination_antenne = nom legacy (pour respecter l'unicité
--     NULLS NOT DISTINCT).
--
-- Volumes attendus (cf mesure phase 0 + recomptage 2026-05-25) :
--   - 11 247 candidates admin (dont 11 091 avec SIRET, 156 sans)
--   - 7 758 SIRETs distincts ; ~104 d'entre eux portent plusieurs noms
--     (réseaux : Emmaüs, Reconnect, Petits Débrouillards…) totalisant
--     ~255 lignes legacy → ~7 758 + (255-104) = ~7 909 lignes admin avec SIRET
--   - 139 lignes admin sans SIRET (cas MIN historiques)
--   - TOTAL attendu : ≈ 8 048 lignes
-- ============================================================

-- (Flyway gère sa propre transaction, pas de BEGIN/COMMIT explicite.)

-- CTE qui calcule is_admin pour chaque ligne main.structure
WITH s_kinds AS (
  SELECT
    s.id,
    (
      EXISTS (SELECT 1 FROM main.personne_affectations pa
              WHERE pa.structure_id = s.id AND pa.type = 'structure_emploi')
      OR EXISTS (SELECT 1 FROM main.contrat            WHERE structure_id = s.id)
      OR EXISTS (SELECT 1 FROM main.poste              WHERE structure_id = s.id)
      OR EXISTS (SELECT 1 FROM main.contact_structure  WHERE structure_id = s.id)
      OR EXISTS (SELECT 1 FROM min.membre              WHERE structure_id = s.id)
      OR EXISTS (SELECT 1 FROM min.utilisateur         WHERE structure_id = s.id)
    ) AS is_admin
  FROM main.structure s
),
-- Candidates avec SIRET : DISTINCT ON (siret, nom) — préserve les "antennes"
candidates_avec_siret AS (
  SELECT DISTINCT ON (s.siret, s.nom)
    s.id, s.siret, s.nom AS nom_legacy, s.denomination_sirene, s.rna, s.adresse_id,
    s.structure_coop_id, s.structure_tp_id, s.structure_ac_id,
    s.etat_administratif, s.code_activite_principale, s.categorie_juridique,
    s.publique, s.nb_mandats_ac, s.contact,
    s.deleted_at, s.deleted_by, s.edited_by,
    s.last_sirene_enrich_at, s.created_at, s.updated_at
  FROM main.structure s
  JOIN s_kinds sk ON sk.id = s.id
  WHERE sk.is_admin
    AND s.siret IS NOT NULL
  ORDER BY s.siret, s.nom,
    CASE s.edited_by
      WHEN 'id-poste'                          THEN 1
      WHEN 'aidants-connect'                   THEN 2
      WHEN 'coop'                              THEN 3
      WHEN 'carto'                             THEN 4
      WHEN 'migrate_ac_addresses.py'           THEN 5
      WHEN 'update_conum_siret_divergences.py' THEN 6
      WHEN 'sonum'                             THEN 7
      WHEN 'app_python'                        THEN 8
      WHEN 'min_scalingo'                      THEN 9
      ELSE 99
    END,
    s.updated_at DESC NULLS LAST,
    s.id  -- tiebreaker stable
),
-- Annoter chaque candidate avec SIRET : denomination_antenne = nom legacy
-- SI ce SIRET a plusieurs noms distincts dans les candidates (= réseau),
-- sinon NULL (= entité unique pour ce SIRET).
candidates_avec_siret_annotees AS (
  SELECT c.*,
    CASE
      WHEN COUNT(*) OVER (PARTITION BY c.siret) > 1 THEN c.nom_legacy
      ELSE NULL
    END AS denomination_antenne
  FROM candidates_avec_siret c
),
-- Candidates sans SIRET : DISTINCT ON (nom) — déduplique les vrais doublons
-- exacts sans-SIRET (ex : "HABITAT JEUNES CANTAL" × 2, "la poste" × 2).
-- denomination_antenne = nom legacy (discriminant requis par
-- UNIQUE NULLS NOT DISTINCT (siret, denomination_antenne)).
candidates_sans_siret AS (
  SELECT DISTINCT ON (s.nom)
    s.id, s.siret, s.nom AS nom_legacy, s.denomination_sirene, s.rna, s.adresse_id,
    s.structure_coop_id, s.structure_tp_id, s.structure_ac_id,
    s.etat_administratif, s.code_activite_principale, s.categorie_juridique,
    s.publique, s.nb_mandats_ac, s.contact,
    s.deleted_at, s.deleted_by, s.edited_by,
    s.last_sirene_enrich_at, s.created_at, s.updated_at,
    s.nom AS denomination_antenne
  FROM main.structure s
  JOIN s_kinds sk ON sk.id = s.id
  WHERE sk.is_admin
    AND s.siret IS NULL
  ORDER BY s.nom,
    CASE s.edited_by
      WHEN 'id-poste'                          THEN 1
      WHEN 'aidants-connect'                   THEN 2
      WHEN 'coop'                              THEN 3
      WHEN 'carto'                             THEN 4
      WHEN 'migrate_ac_addresses.py'           THEN 5
      WHEN 'update_conum_siret_divergences.py' THEN 6
      WHEN 'sonum'                             THEN 7
      WHEN 'app_python'                        THEN 8
      WHEN 'min_scalingo'                      THEN 9
      ELSE 99
    END,
    s.updated_at DESC NULLS LAST,
    s.id
),
candidates AS (
  SELECT * FROM candidates_avec_siret_annotees
  UNION ALL
  SELECT * FROM candidates_sans_siret
)
INSERT INTO main.structure_administrative (
  old_main_structure_id,
  siret, ridet, denomination_sirene, rna,
  denomination_antenne,
  adresse_id,
  structure_coop_id, structure_tp_id, structure_ac_id,
  etat_administratif, code_activite_principale, categorie_juridique,
  publique, nb_mandats_ac,
  contact,
  deleted_at, deleted_by,
  edited_by, last_sirene_enrich_at,
  created_at, updated_at
)
SELECT
  c.id AS old_main_structure_id,
  c.siret, NULL AS ridet,  -- ridet vide à ce stade (aucune occurrence en base)
  c.denomination_sirene, c.rna,
  c.denomination_antenne,
  c.adresse_id,
  c.structure_coop_id, c.structure_tp_id, c.structure_ac_id,
  c.etat_administratif, c.code_activite_principale, c.categorie_juridique,
  c.publique, c.nb_mandats_ac,
  c.contact,  -- JSONB conservé tel quel (V047 fermeture reportée — phase Next N1)
  c.deleted_at, c.deleted_by,
  c.edited_by, c.last_sirene_enrich_at,
  c.created_at, c.updated_at
FROM candidates c;

-- Avancer la sequence pour éviter les collisions sur les futurs INSERT auto
SELECT setval(
  pg_get_serial_sequence('main.structure_administrative', 'id'),
  COALESCE((SELECT MAX(id) FROM main.structure_administrative), 1)
);

-- Vérification post-INSERT
-- Invariants attendus :
--  - 0 doublon (siret, denomination_antenne) — garanti par la contrainte UNIQUE
--  - sirets distincts >= 7 700 (ordre de grandeur baseline phase 0)
--  - sans-siret >= 130 (cas MIN historiques)
--  - antennes (denomination_antenne IS NOT NULL côté avec-siret) ≈ 250
--    (~104 SIRETs portent ~255 noms legacy)
DO $$
DECLARE
  total INTEGER;
  avec_siret INTEGER;
  sans_siret INTEGER;
  sirets_distincts INTEGER;
  antennes_avec_siret INTEGER;
BEGIN
  SELECT COUNT(*) INTO total FROM main.structure_administrative;
  SELECT COUNT(*) INTO avec_siret FROM main.structure_administrative WHERE siret IS NOT NULL;
  SELECT COUNT(*) INTO sans_siret FROM main.structure_administrative WHERE siret IS NULL;
  SELECT COUNT(DISTINCT siret) INTO sirets_distincts FROM main.structure_administrative WHERE siret IS NOT NULL;
  SELECT COUNT(*) INTO antennes_avec_siret
    FROM main.structure_administrative WHERE siret IS NOT NULL AND denomination_antenne IS NOT NULL;
  RAISE NOTICE 'V073 peuplement structure_administrative : total=% (avec_siret=%, sirets_distincts=%, antennes=%, sans_siret=%)',
    total, avec_siret, sirets_distincts, antennes_avec_siret, sans_siret;
END $$;
