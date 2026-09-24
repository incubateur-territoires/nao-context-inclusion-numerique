-- ============================================================
-- V121 – Intégration coop : nouvelles colonnes sur main.lieu_inclusion
-- ============================================================
-- CONTEXTE (issue SEPT #1700) :
-- coop-mediation-numerique bascule sur les tables de l'Entrepôt
-- (main.lieu_inclusion / main.structure_administrative). Côté coop, la table
-- `structures` a été renommée coop.lieu_inclusion (inc. 2a) ; trois champs
-- qu'elle porte n'existent pas encore côté Entrepôt.
--
-- DÉCISIONS :
--   - complement_adresse vit sur lieu_inclusion, PAS sur main.adresse :
--     main.adresse est normalisée BAN et mutualisée (3 744 adresses
--     référencées par plusieurs lieux, 2 424 partagées SA↔lieu au moment de
--     la migration) — un complément y fuiterait entre entités. Le complément
--     («Bâtiment B, 2e étage»…) est une propriété du lieu, pas de l'adresse.
--   - siret_a_l_enrichissement est DÉCLARATIF : saisi à la création du lieu
--     côté coop, il sert d'entrée au pipeline d'association lieu↔SA. Le SIRET
--     canonique reste porté par la structure_administrative liée par asso
--     (doctrine V069).
-- ============================================================

ALTER TABLE main.lieu_inclusion
    ADD COLUMN complement_adresse TEXT,
    ADD COLUMN siret_a_l_enrichissement CHARACTER VARYING(14),
    ADD COLUMN nom_usage CHARACTER VARYING(255);

COMMENT ON COLUMN main.lieu_inclusion.complement_adresse IS
  'Complément d''adresse libre saisi à la main sur le lieu (bâtiment, étage…). '
  'Propriété du lieu et non de main.adresse (normalisée BAN, mutualisée entre lieux et SA).';

COMMENT ON COLUMN main.lieu_inclusion.siret_a_l_enrichissement IS
  'SIRET déclaré à la création du lieu côté coop-mediation-numerique. Entrée '
  'déclarative pour l''enrichissement / l''association lieu↔structure_administrative ; '
  'le SIRET canonique reste celui de la structure_administrative liée par asso (cf V069).';

COMMENT ON COLUMN main.lieu_inclusion.nom_usage IS
  'Nom d''usage du lieu, saisi côté coop-mediation-numerique (coop.lieu_inclusion.nom_usage).';
