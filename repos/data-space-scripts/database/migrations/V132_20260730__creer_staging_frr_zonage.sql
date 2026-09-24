-- Silver du flux FRR (zonage France Ruralités Revitalisation, mensuel) :
-- l'état transformé du run (XLSX officiel filtré : code_insee à 5 caractères,
-- hors « Non classée ») est matérialisé dans staging au lieu d'un CSV du
-- working_dir effacé en fin de run. Table reconstruite à chaque run
-- (TRUNCATE + INSERT), relue par la capture source et par l'insert vers
-- admin.zonage.
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

CREATE TABLE staging.frr__zonage (
    run_id      TEXT        NOT NULL,
    staged_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    code_insee  TEXT        NOT NULL,
    type        TEXT        NOT NULL,
    commentaire TEXT
);
