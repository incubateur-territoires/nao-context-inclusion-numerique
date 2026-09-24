-- Labellisation conseiller numérique (suite-gestionnaire-numerique#1776) :
-- l'attestation sur l'honneur cliquée à la fin du parcours de labellisation
-- crée une ligne — une ligne par attestation, jamais d'UPDATE. Le renouvellement
-- insère une nouvelle ligne ; « label actif » = date_attestation la plus
-- récente de moins d'un an (durée calculée côté applicatif, non stockée, car
-- non figée métier à ce jour).
-- L'attestant référence min.utilisateur.id (clé interne) — jamais de FK sur
-- sso_id (identifiant externe ProConnect).
CREATE TABLE IF NOT EXISTS main.conum_labellisation (
    id SERIAL NOT NULL,
    structure_id INTEGER NOT NULL,
    utilisateur_id INTEGER NOT NULL,
    date_attestation TIMESTAMP(3) NOT NULL,

    CONSTRAINT conum_labellisation_pkey PRIMARY KEY (id),
    CONSTRAINT conum_labellisation_structure_id_fkey
        FOREIGN KEY (structure_id) REFERENCES main.structure_administrative(id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT conum_labellisation_utilisateur_id_fkey
        FOREIGN KEY (utilisateur_id) REFERENCES min.utilisateur(id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Lecture systématiquement par structure (label actif = max(date_attestation)).
CREATE INDEX IF NOT EXISTS conum_labellisation_structure_id_idx
    ON main.conum_labellisation(structure_id);

-- min_scalingo (rôle applicatif MIN) écrit l'attestation et lit l'état du
-- label ; table en append-only, pas d'UPDATE ni de DELETE.
GRANT SELECT, INSERT ON TABLE main.conum_labellisation TO min_scalingo;
GRANT USAGE ON SEQUENCE main.conum_labellisation_id_seq TO min_scalingo;
