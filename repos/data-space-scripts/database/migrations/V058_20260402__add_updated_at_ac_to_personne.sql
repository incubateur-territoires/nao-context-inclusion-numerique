ALTER TABLE main.personne
    ADD COLUMN IF NOT EXISTS updated_at_ac TIMESTAMP WITHOUT TIME ZONE;

COMMENT ON COLUMN main.personne.updated_at_ac
    IS 'Dernière date de mise à jour côté API Aidants Connect (updated_at)';
