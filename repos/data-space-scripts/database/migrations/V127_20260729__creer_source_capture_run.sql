-- Journal des runs de capture de la couche source (fiche 08, étape 1).
-- Socle de l'observabilité : 1 ligne = 1 capture (run Airflow × table cible),
-- créée dès l'ouverture du sink (nb_lignes = 0), puis cumulée lot par lot.
--
-- Permet de distinguer les deux cas aujourd'hui indistinguables sur un flux
-- incrémental (ex. ac__aidants) : « run exécuté, 0 ligne reçue » (normal, rien
-- n'a changé côté source) vs « pas de capture du tout » (échec silencieux).
--
--   run_id        run Airflow qui a produit la capture (même valeur que dans
--                 les tables source.* — jointure de corrélation)
--   table_cible   table de capture qualifiée (ex. 'source.ac__aidants')
--   nb_lignes     cumul des lignes insérées par le run dans la table cible
--   demarre_le    ouverture du sink (début de capture)
--   derniere_capture_le  horodatage du dernier lot inséré (NULL si 0 ligne)
--   parametres    contexte du fetch, notamment le curseur des flux
--                 incrémentaux (ex. {"updated_at__gte": "..."}) — rend chaque
--                 delta ré-interprétable sans dépendre de l'état de main
--
-- Écriture par lots : INSERT ... ON CONFLICT (run_id, table_cible)
-- DO UPDATE SET nb_lignes = nb_lignes + n (index unique ci-dessous).
-- GRANTs : hérités des ALTER DEFAULT PRIVILEGES de V099 (app_python) et
-- V114 (min_scalingo, SELECT).

CREATE TABLE source.capture_run (
    id                  BIGSERIAL   PRIMARY KEY,
    run_id              TEXT        NOT NULL,
    table_cible         TEXT        NOT NULL,
    nb_lignes           BIGINT      NOT NULL DEFAULT 0,
    demarre_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
    derniere_capture_le TIMESTAMPTZ,
    parametres          JSONB
);

CREATE UNIQUE INDEX capture_run_run_id_table_cible_uidx
    ON source.capture_run (run_id, table_cible);

COMMENT ON TABLE source.capture_run IS
    'Journal des runs de capture brute : 1 ligne par (run Airflow, table source.*), volumétrie cumulée par lots. nb_lignes = 0 signifie « capture exécutée, rien reçu ».';
COMMENT ON COLUMN source.capture_run.parametres IS
    'Contexte du fetch (JSONB), ex. curseur incrémental {"updated_at__gte": ...}.';
