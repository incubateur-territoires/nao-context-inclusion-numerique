ALTER TABLE main.personne
    ADD COLUMN deleted_at TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN deleted_by text[];

ALTER TABLE main.structure
    ADD COLUMN deleted_at TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN deleted_by text[];
