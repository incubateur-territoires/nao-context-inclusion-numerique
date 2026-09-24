ALTER TABLE main.adresse
    ALTER COLUMN code_insee SET NOT NULL,
    ALTER COLUMN nom_commune SET NOT NULL,
    ALTER COLUMN code_postal SET NOT NULL;
