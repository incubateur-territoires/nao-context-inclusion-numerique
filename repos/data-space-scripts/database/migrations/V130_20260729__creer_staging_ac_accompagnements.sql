-- Silver du flux Aidants Connect accompagnements (snapshot mensuel) : l'état
-- transformé du run (dépliage de la fenêtre glissante 6 mois en lignes
-- (aidant, mois)) est matérialisé dans staging avant l'upsert vers
-- main.ac_accompagnements_mensuels. Table reconstruite à chaque run
-- (TRUNCATE + INSERT), 100 % re-dérivable depuis source.ac__aidants +
-- etl/core/ac.py (transformer_accompagnements).
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

CREATE TABLE staging.ac__accompagnements (
    run_id             TEXT        NOT NULL,
    staged_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    aidant_connect_id  BIGINT      NOT NULL,
    mois               DATE        NOT NULL,
    nb_accompagnements INTEGER     NOT NULL
);
