ALTER TABLE import.carto
    ADD COLUMN structure_id INTEGER REFERENCES main.structure(id) ON DELETE SET NULL;
