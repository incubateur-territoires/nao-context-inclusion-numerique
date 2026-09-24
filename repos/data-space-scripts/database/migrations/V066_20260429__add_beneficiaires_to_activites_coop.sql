-- Ajout du champ bénéficiaires (non nominatif) sur main.activites_coop.
--
-- Contexte : ticket #1215 — l'API coop-numerique expose pour chaque activité
-- un objet `beneficiaires` agrégé (genres, tranches d'âge, statuts) destiné
-- aux graphiques d'accompagnement de la Suite Gestionnaire Numérique.
-- V1 = stockage non nominatif. V2 (suivi par personne) viendra plus tard.

ALTER TABLE main.activites_coop
    ADD COLUMN IF NOT EXISTS beneficiaires JSONB;

COMMENT ON COLUMN main.activites_coop.beneficiaires
    IS 'Agrégats non nominatifs des bénéficiaires de l''activité (total, genres, tranches_age, statuts). Source: API coop-numerique /api/v1/activites attributes.beneficiaires';
