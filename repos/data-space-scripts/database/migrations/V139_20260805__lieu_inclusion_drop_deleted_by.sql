-- Suppression de la colonne deleted_by sur main.lieu_inclusion
-- Contexte : suppression d'un lieu depuis MIN (suite-gestionnaire-numerique#1497).
-- L'auteur de la suppression est déjà tracé par l'audit trail source.min__evenements
-- (user_id + snapshot) : la colonne deleted_by est redondante et son contenu
-- (référence externe SSO) n'était pas exploitable. Seul deleted_at porte le soft delete.

ALTER TABLE main.lieu_inclusion
    DROP COLUMN IF EXISTS deleted_by;
