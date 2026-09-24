-- Tracer l'auteur de la modification (création ou mise à jour)
CREATE OR REPLACE FUNCTION edited_by_column() RETURNS TRIGGER AS $$
BEGIN
    -- Si la valeur est fournie dans la requête SQL, l'utiliser
    -- Sinon on récupère la valeur de current_user de la connexion à la base de données
    IF NEW.edited_by IS NULL THEN
        NEW.edited_by = current_user;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Tables tracées
ALTER TABLE main.structure ADD COLUMN edited_by character varying(50);
CREATE TRIGGER edited_by BEFORE INSERT OR UPDATE ON main.structure FOR EACH ROW EXECUTE PROCEDURE edited_by_column();

ALTER TABLE main.personne ADD COLUMN edited_by character varying(50);
CREATE TRIGGER edited_by BEFORE INSERT OR UPDATE ON main.personne FOR EACH ROW EXECUTE PROCEDURE edited_by_column();
