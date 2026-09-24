-- ============================================================
-- V150 – dataviz.personne_doublons_intra_source
-- ============================================================
-- CONTEXTE (ticket SEPT #1824, successeur des DAGs similarities N11/N13) :
-- les doublons de personnes INTRA-source (deux aidant_connect_id, deux
-- coop_id ou deux cn_pg_id pour le même nom sur la même structure) ne sont
-- PAS fusionnables côté entrepôt : ce sont deux comptes vivants de la
-- source, recréés à l'import suivant si on les fusionne (constaté sur
-- 277/640 fusions de l'ancien DAG). Ils sont détectés et publiés ici pour
-- être traités À LA SOURCE (équipes coop / Conseiller Numérique / AC).
--
-- Table TRUNCATE + INSERT à chaque run du DAG personne-reconciliation
-- (quotidien) : photographie du stock courant, pas un historique.

CREATE TABLE dataviz.personne_doublons_intra_source (
    source                      text        NOT NULL,  -- 'aidants-connect' | 'coop' | 'conseiller-numerique'
    personne_id_1               integer     NOT NULL,
    personne_id_2               integer     NOT NULL,
    source_id_1                 text        NOT NULL,  -- les deux ids source distincts
    source_id_2                 text        NOT NULL,
    prenom                      text        NOT NULL,
    nom                         text        NOT NULL,
    structure_administrative_id integer     NOT NULL,
    denomination_structure      text,
    detecte_le                  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE dataviz.personne_doublons_intra_source IS
  'Doublons de personnes intra-source (même nom normalisé, même structure administrative, '
  'deux identifiants distincts de la même source). Photographie TRUNCATE+INSERT par le DAG '
  'personne-reconciliation. Non fusionnables côté entrepôt : à résoudre à la source (#1824).';

GRANT USAGE ON SCHEMA dataviz TO app_python;
GRANT SELECT, INSERT, DELETE, TRUNCATE ON dataviz.personne_doublons_intra_source TO app_python;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_metabase') THEN
        EXECUTE 'GRANT SELECT ON dataviz.personne_doublons_intra_source TO app_metabase';
    END IF;
END $$;
