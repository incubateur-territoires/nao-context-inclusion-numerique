-- Marquer les tables main.structure et main.personne_affectations comme deprecated.

COMMENT ON TABLE main.structure IS
  'DEPRECATED - Remplacee par main.structure_administrative (V068). Ne plus utiliser pour les nouveaux developpements.';

COMMENT ON TABLE main.personne_affectations IS
  'DEPRECATED - Remplacee par main.personne_affectations_emploi (V071) et main.personne_affectations_lieu (V072). Ne plus utiliser pour les nouveaux developpements.';
