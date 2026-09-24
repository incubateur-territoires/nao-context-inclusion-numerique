-- Ajout des timestamps source-spécifiques sur main.personne.
--
-- Contexte : updated_at (global) est bumpé par chaque DAG qui écrit la ligne,
-- même sans réel changement métier (ex: edited_by = 'idposte' à chaque run).
-- Résultat : coop-dag comparait s.updated_at_coop > p.updated_at et voyait
-- toujours p.updated_at comme "plus récent", donc skippait les MAJ légitimes
-- (ex: téléphone coop non mis à jour après un run idposte).
--
-- Solution : chaque DAG compare contre son propre horodatage source, comme
-- le fait déjà aidants-connect avec updated_at_ac (V058).

ALTER TABLE main.personne
    ADD COLUMN IF NOT EXISTS updated_at_coop TIMESTAMP WITHOUT TIME ZONE;

ALTER TABLE main.personne
    ADD COLUMN IF NOT EXISTS updated_at_idposte TIMESTAMP WITHOUT TIME ZONE;

COMMENT ON COLUMN main.personne.updated_at_coop
    IS 'Dernière date de mise à jour côté API coop-numerique (utilisateurs.updated_at)';
COMMENT ON COLUMN main.personne.updated_at_idposte
    IS 'Dernière date de mise à jour côté extract idposte (timestamp du batch)';

-- Backfill : approximer les horodatages source à partir de edited_by / updated_at.
-- Seule la dernière source éditrice est connue via edited_by, donc les autres
-- colonnes restent NULL (le prochain run du DAG concerné les peuplera).
UPDATE main.personne
SET updated_at_coop = COALESCE(updated_at, created_at)
WHERE edited_by = 'coop' AND updated_at_coop IS NULL;

UPDATE main.personne
SET updated_at_idposte = COALESCE(updated_at, created_at)
WHERE edited_by = 'id-poste' AND updated_at_idposte IS NULL;
