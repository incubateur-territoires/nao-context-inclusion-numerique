-- Silver du flux SIRENE (sirene-backfill, quotidien 04h00) : l'état transformé
-- du run (sortie parsée de SireneBatch.enrichir_dataframe — une ligne par
-- structure sélectionnée, avec les attributs SIRENE de son SIRET ou des NULL
-- si introuvable) vivait uniquement en mémoire entre le parse et l'UPDATE de
-- main.structure. Il est matérialisé ici : TRUNCATE + INSERT à chaque run,
-- relu filtré sur run_id par l'étape d'UPDATE.
--
-- structure_id (= main.structure.id, id_source côté SireneBatch) fait partie
-- de l'état capturé : la sélection du run n'est pas re-dérivable a posteriori
-- (last_sirene_enrich_at évolue à chaque run).
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

CREATE TABLE staging.sirene__etablissements (
    run_id                    TEXT        NOT NULL,
    staged_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    structure_id              BIGINT      NOT NULL,
    siret                     TEXT        NOT NULL,
    etat_administratif        TEXT,
    code_activite_principale  TEXT,
    categorie_juridique       TEXT,
    denomination_sirene       TEXT,
    adresse_sirene            TEXT,
    code_insee_sirene         TEXT,
    code_postal_sirene        TEXT,
    date_creation_sirene      DATE,
    tranche_effectifs_sirene  TEXT,
    sirene_trouve             BOOLEAN     NOT NULL
);
