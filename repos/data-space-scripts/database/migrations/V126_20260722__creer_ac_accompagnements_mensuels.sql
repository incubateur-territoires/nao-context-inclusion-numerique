-- Historique mensuel des accompagnements par aidant (Aidants Connect).
--
-- L'API AC ne renvoie qu'une fenêtre glissante de 6 mois
-- (get_supports_number_last_six_months : index 0 = mois courant, 5 = M-5).
-- Un snapshot mensuel (DAG aidants-connect-accompagnements, le 1er de chaque
-- mois) reconstruit la série temporelle complète : les mois se recouvrant
-- d'un snapshot à l'autre sont mis à jour avec la valeur la plus fraîche.

CREATE TABLE IF NOT EXISTS main.ac_accompagnements_mensuels (
    aidant_connect_id  BIGINT      NOT NULL,
    mois               DATE        NOT NULL,
    nb_accompagnements INTEGER     NOT NULL,
    fetched_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (aidant_connect_id, mois),
    CONSTRAINT mois_premier_jour CHECK (mois = date_trunc('month', mois)::date)
);

COMMENT ON TABLE main.ac_accompagnements_mensuels IS
    'Nombre d''accompagnements par aidant et par mois, snapshoté mensuellement depuis l''API Aidants Connect (fenêtre glissante de 6 mois, upsert sur recouvrement).';
COMMENT ON COLUMN main.ac_accompagnements_mensuels.aidant_connect_id IS
    'Identifiant de l''aidant côté Aidants Connect (champ id de l''API).';
COMMENT ON COLUMN main.ac_accompagnements_mensuels.mois IS
    'Premier jour du mois concerné (index 0 du payload = mois du fetch, 1 = M-1, etc.).';
COMMENT ON COLUMN main.ac_accompagnements_mensuels.nb_accompagnements IS
    'Nombre d''accompagnements du mois, dernière valeur connue (le mois courant est partiel jusqu''au snapshot suivant).';
COMMENT ON COLUMN main.ac_accompagnements_mensuels.fetched_at IS
    'Horodatage du dernier snapshot ayant écrit ou mis à jour la ligne.';
