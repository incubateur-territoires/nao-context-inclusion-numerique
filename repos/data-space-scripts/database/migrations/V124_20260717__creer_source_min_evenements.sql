-- Capture des événements de modification effectués depuis l'application MIN
-- (Mon Inclusion Numérique), traitée comme une source parmi les autres de la
-- couche "source" brute (V099) : structure canonique commune, append-only.
--
--   run_id      identifiant de corrélation côté app MIN (pas un run Airflow)
--   source_key  nom de l'entité modifiée (ex : structure, personne, lieu)
--   donnee      événement complet : {"action", "entity_id", "actor", "value"}
--               * action create : value = snapshot complet de l'entité créée
--               * action update : value = {"old": …, "new": …} limités aux
--                 propriétés modifiées
--               * action delete : value = snapshot complet de l'entité supprimée
--
-- Les invariants métier (actions autorisées, forme old/new) sont garantis par
-- l'app MIN, comme pour toute source externe — pas de CHECK côté base.
--
-- Grants hérités des default privileges du schéma source :
--   * app_python (V099) : SELECT/INSERT/UPDATE/DELETE/TRUNCATE — l'ETL pourra
--     lire ce flux comme n'importe quelle autre table source ;
--   * min_scalingo (V114) : SELECT — conservé, MIN peut relire son journal.

CREATE TABLE source.min__evenements (
    id          BIGSERIAL   PRIMARY KEY,
    run_id      TEXT        NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_key  TEXT        NOT NULL,
    donnee      JSONB       NOT NULL
);

COMMENT ON TABLE source.min__evenements IS
    'Capture append-only des événements de modification (create/update/delete) émis par l''application MIN. Producteur : min_scalingo (seule table source non alimentée par l''ETL).';
COMMENT ON COLUMN source.min__evenements.run_id IS 'Identifiant de corrélation côté app MIN (request id), pas un run Airflow.';
COMMENT ON COLUMN source.min__evenements.source_key IS 'Nom de l''entité modifiée (ex : structure, personne, lieu).';
COMMENT ON COLUMN source.min__evenements.donnee IS 'Événement complet : action, entity_id, actor, value (create/delete : snapshot ; update : {"old", "new"} limités aux propriétés modifiées).';

-- Historique d'une entité, du plus récent au plus ancien (usage de lecture
-- principal : MIN affiche le journal d'une fiche, l'ETL rejoue un flux).
CREATE INDEX min__evenements_entity_idx
    ON source.min__evenements (source_key, (donnee ->> 'entity_id'), ingested_at DESC);

-- MIN est le producteur de ce flux : INSERT explicite (V114 ne donne que SELECT)
-- + USAGE sur la séquence, sans quoi l'INSERT échoue à générer l'id.
GRANT INSERT ON TABLE source.min__evenements TO min_scalingo;
GRANT USAGE ON SEQUENCE source.min__evenements_id_seq TO min_scalingo;
