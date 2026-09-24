-- Index sur admin.region (nom et code)
CREATE INDEX IF NOT EXISTS region_nom_idx ON admin.region (nom);
CREATE UNIQUE INDEX IF NOT EXISTS region_code_idx ON admin.region (code);

-- Index sur admin.departement (nom et code)
CREATE INDEX IF NOT EXISTS departement_nom_idx ON admin.departement (nom);
CREATE UNIQUE INDEX IF NOT EXISTS departement_code_idx ON admin.departement (code);
