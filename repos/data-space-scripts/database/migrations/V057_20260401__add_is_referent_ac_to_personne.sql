ALTER TABLE main.personne
    ADD COLUMN IF NOT EXISTS is_referent_ac BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN main.personne.is_referent_ac
    IS 'Indique si la personne est référente (non aidante active) selon Aidants Connect';
