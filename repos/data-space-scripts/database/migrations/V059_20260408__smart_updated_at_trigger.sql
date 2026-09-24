-- Ne met à jour updated_at que si les données ont réellement changé.
-- Évite les faux updated_at lors des réimports carto/AC quotidiens
-- qui touchent toutes les lignes même sans changement de données.
CREATE OR REPLACE FUNCTION updated_at_column() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.updated_at = now();
    ELSIF NEW IS DISTINCT FROM OLD THEN
        NEW.updated_at = now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Ajouter un trigger BEFORE INSERT sur toutes les tables qui ont le trigger updated_at
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.adresse FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.structure FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.personne FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.formation FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.activites_coop FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.poste FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.contrat FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.coordination_mediation FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.personne_affectations FOR EACH ROW EXECUTE FUNCTION updated_at_column();
CREATE OR REPLACE TRIGGER updated_at_insert BEFORE INSERT ON main.subvention FOR EACH ROW EXECUTE FUNCTION updated_at_column();

-- Remplir updated_at pour les lignes existantes qui n'en ont pas
UPDATE main.structure SET updated_at = created_at WHERE updated_at IS NULL AND created_at IS NOT NULL;
UPDATE main.personne SET updated_at = created_at WHERE updated_at IS NULL AND created_at IS NOT NULL;
UPDATE main.adresse SET updated_at = created_at WHERE updated_at IS NULL AND created_at IS NOT NULL;
