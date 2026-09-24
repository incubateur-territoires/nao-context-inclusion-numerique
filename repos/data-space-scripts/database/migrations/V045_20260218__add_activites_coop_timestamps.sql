-- ============================================================
-- V045 – Ajouter created_at_coop et updated_at_coop a main.activites_coop
-- ============================================================

ALTER TABLE main.activites_coop
    ADD COLUMN created_at_coop TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN updated_at_coop TIMESTAMP WITHOUT TIME ZONE;
