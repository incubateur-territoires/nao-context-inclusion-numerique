-- Soft delete sur main.lieu_inclusion
-- Contexte : suppression d'un lieu depuis MIN (suite-gestionnaire-numerique#1497).
-- Le lieu supprimé est conservé avec toutes ses relations (personnes, activités,
-- statistiques) mais ne doit plus être retourné dans les listes de lieux actifs
-- ni propagé vers la cartographie nationale / la Coop.

ALTER TABLE main.lieu_inclusion
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN IF NOT EXISTS deleted_by TEXT;

COMMENT ON COLUMN main.lieu_inclusion.deleted_at IS
  'Date de suppression logique (soft delete). NULL = lieu actif.';

COMMENT ON COLUMN main.lieu_inclusion.deleted_by IS
  'Utilisateur MIN ayant supprimé le lieu.';
