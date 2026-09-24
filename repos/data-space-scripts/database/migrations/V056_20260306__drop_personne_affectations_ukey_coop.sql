-- Suppression de la contrainte d'unicité technique coop
-- (structure_coop_id, mediateur_coop_id, type) qui entre en conflit
-- avec la contrainte métier (structure_id, personne_id, type, source)
-- lors de la réconciliation des structures.
DROP INDEX IF EXISTS main.personne_affectations_ukey;
