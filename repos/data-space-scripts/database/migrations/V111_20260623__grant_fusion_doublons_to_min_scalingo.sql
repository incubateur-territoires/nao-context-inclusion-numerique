-- Accorder DELETE à min_scalingo sur main.personne_affectations_emploi.
--
-- Contexte : la feature "structures-doublons" (fusion de structures) de l'app MIN
-- exécute, dans une transaction atomique, des UPDATE collision-aware puis des DELETE
-- sur main.personne_affectations_emploi (repointage des affectations de la structure
-- absorbée vers la survivante, puis suppression des résidus irréconciliables).
--
-- En V091, min_scalingo n'avait reçu que SELECT, INSERT, UPDATE, REFERENCES sur cette
-- table (DELETE volontairement omis car l'app n'était pas censée supprimer ces lignes).
-- La fusion en a désormais besoin → erreur 42501 "permission denied for table
-- personne_affectations_emploi" en prod.

GRANT DELETE ON TABLE main.personne_affectations_emploi TO min_scalingo;
