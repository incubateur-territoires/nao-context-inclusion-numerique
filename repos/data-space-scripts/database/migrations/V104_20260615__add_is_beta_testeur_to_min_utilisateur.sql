ALTER TABLE min.utilisateur
    ADD COLUMN IF NOT EXISTS is_beta_testeur BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN min.utilisateur.is_beta_testeur
    IS 'Réservé à un nombre restreint d''utilisateurs (dév / support avancé) pour ouvrir l''accès à des fonctionnalités en cours';
