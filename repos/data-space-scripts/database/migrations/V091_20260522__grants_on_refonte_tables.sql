-- ============================================================
-- V091 – Refonte phase 5.x : aligner GRANTs sur les nouvelles tables
-- ============================================================
-- CONTEXTE :
-- Les tables créées en V068-V072 (structure_administrative, lieu_inclusion,
-- lieu_inclusion_structure_administrative, personne_affectations_emploi,
-- personne_affectations_lieu) n'ont que les privilèges du owner par défaut
-- (dataspace), alors que main.structure legacy a des grants sur sonum,
-- app_python, min_scalingo, min_dev.
--
-- Conséquence concrète détectée pendant phase 5.3 : la vue api.carto_departement
-- (owner sonum) ne pouvait pas accéder à main.lieu_inclusion car sonum n'avait
-- pas SELECT. PostgreSQL utilise les privilèges du owner de la vue pour
-- résoudre les accès aux tables sous-jacentes (comportement default-SECURITY
-- DEFINER pour les vues).
--
-- On aligne les nouvelles tables sur les mêmes grants que main.structure legacy.
-- ============================================================

-- sonum : R/W (owner des vues api.*, DAG actuel)
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON main.structure_administrative TO sonum;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON main.lieu_inclusion TO sonum;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON main.lieu_inclusion_structure_administrative TO sonum;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON main.personne_affectations_emploi TO sonum;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON main.personne_affectations_lieu TO sonum;

-- app_python : R/W (scripts Python d'enrich)
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON main.structure_administrative TO app_python;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON main.lieu_inclusion TO app_python;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON main.lieu_inclusion_structure_administrative TO app_python;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON main.personne_affectations_emploi TO app_python;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON main.personne_affectations_lieu TO app_python;

-- min_scalingo : R/W (côté écriture MIN)
GRANT SELECT, INSERT, UPDATE, REFERENCES
  ON main.structure_administrative TO min_scalingo;
GRANT SELECT, INSERT, UPDATE, REFERENCES
  ON main.lieu_inclusion TO min_scalingo;
GRANT SELECT, INSERT, UPDATE, REFERENCES
  ON main.lieu_inclusion_structure_administrative TO min_scalingo;
GRANT SELECT, INSERT, UPDATE, REFERENCES
  ON main.personne_affectations_emploi TO min_scalingo;
GRANT SELECT, INSERT, UPDATE, REFERENCES
  ON main.personne_affectations_lieu TO min_scalingo;

-- min_dev : read-only (lecture dev MIN)
GRANT SELECT ON main.structure_administrative TO min_dev;
GRANT SELECT ON main.lieu_inclusion TO min_dev;
GRANT SELECT ON main.lieu_inclusion_structure_administrative TO min_dev;
GRANT SELECT ON main.personne_affectations_emploi TO min_dev;
GRANT SELECT ON main.personne_affectations_lieu TO min_dev;

-- Pas de NOTIFY pgrst : on ne change pas le schéma api.*
