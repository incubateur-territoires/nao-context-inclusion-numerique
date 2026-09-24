-- Silver du flux idposte (fiche 01 approche-data) : les 6 CSV du working_dir
-- produits par etl/transform/ingest/postes_conum.py (structure, poste,
-- personne, formation, subvention, contrat) sortent des fichiers temporaires
-- vers le schéma staging. Tables reconstruites à chaque run (TRUNCATE +
-- INSERT), 100 % re-dérivables depuis la capture brute source.idposte__conum.
--
-- L'état POST-enrichissement SIRENE/BAN (ex structure_enriched.csv) reste
-- hors staging : non re-dérivable (APIs externes) — problème ouvert documenté
-- fiche 08 (cible fiche 05 : enrichissements dans leurs propres tables
-- staging.sirene_* / staging.geocodage_*).
--
-- Les colonnes portant du JSON (contact) restent en TEXT : forme produite par
-- le transform, castée ::jsonb par les ingests — inchangé.
--
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

-- Sous-flux structure (dédupliqué par structure_tp_id, entrée de
-- l'enrichissement SIRENE+BAN).
CREATE TABLE staging.idposte__structure (
    run_id          TEXT        NOT NULL,
    staged_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    structure_tp_id BIGINT,
    nom             TEXT,
    siret           TEXT,
    publique        BOOLEAN,
    adresse         TEXT,
    code_insee      TEXT,
    code_postal     TEXT, -- artefacts float du CSV source possibles ("03600.0") : TEXT
    contact         TEXT  -- JSON contact référent, casté ::jsonb à l'ingest
);

-- Sous-flux poste (dédupliqué par (poste_conum_id, structure_tp_id, cn_pg_id)).
CREATE TABLE staging.idposte__poste (
    run_id              TEXT        NOT NULL,
    staged_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    poste_conum_id      BIGINT      NOT NULL,
    structure_tp_id     BIGINT,
    etat                TEXT,
    etat_instruction_v1 TEXT,
    etat_instruction_v2 TEXT,
    cn_pg_id            BIGINT,
    date_attribution    DATE,
    date_rendu_poste    DATE,
    typologie           TEXT,
    origine_transfert   BIGINT,
    poste_renouvele     BOOLEAN,
    action_coselec      TEXT
);

-- Sous-flux personne (dédupliqué par cn_pg_id).
CREATE TABLE staging.idposte__personne (
    run_id          TEXT        NOT NULL,
    staged_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    cn_pg_id        BIGINT      NOT NULL,
    structure_tp_id BIGINT,
    nom             TEXT,
    prenom          TEXT,
    contact         TEXT -- JSON {"idposte": {mail_pro, mail_perso}}, casté ::jsonb à l'ingest
);

-- Sous-flux formation (dédupliqué par personne_id_pg).
CREATE TABLE staging.idposte__formation (
    run_id           TEXT        NOT NULL,
    staged_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    personne_id_pg   BIGINT      NOT NULL,
    lot              BIGINT,
    marche_formation TEXT,
    label            TEXT,
    date_debut       DATE,
    date_fin         DATE,
    lieu             TEXT,
    parcours         TEXT,
    pix              BOOLEAN,
    remn             BOOLEAN,
    observations     TEXT
);

-- Sous-flux subvention (agrégé : une ligne par poste, montants sommés).
CREATE TABLE staging.idposte__subvention (
    run_id                                 TEXT        NOT NULL,
    staged_at                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    poste_id                               BIGINT      NOT NULL,
    date_debut_convention_dgcl             DATE,
    date_debut_financement_dgcl            DATE,
    date_fin_convention_dgcl               DATE,
    date_fin_financement_dgcl              DATE,
    mois_utilises_periode_financement_dgcl BIGINT,
    date_debut_convention_ditp             DATE,
    date_debut_financement_ditp            DATE,
    date_fin_convention_ditp               DATE,
    date_fin_financement_ditp              DATE,
    mois_utilises_periode_financement_ditp BIGINT,
    date_debut_convention_dge              DATE,
    date_debut_financement_dge             DATE,
    date_fin_convention_dge                DATE,
    date_fin_financement_dge               DATE,
    mois_utilises_periode_financement_dge  BIGINT,
    montant_subvention_v1                  BIGINT,
    montant_versement_v1                   BIGINT,
    montant_avoir_v1                       BIGINT,
    montant_bonification_v2                BIGINT,
    montant_subvention_v2                  BIGINT,
    montant_avoir_v2                       BIGINT,
    versement_1_v2                         BIGINT,
    versement_2_v2                         BIGINT,
    versement_3_v2                         BIGINT,
    date_versement_1_v2                    DATE,
    date_versement_2_v2                    DATE,
    date_versement_3_v2                    DATE
);

-- Sous-flux contrat.
CREATE TABLE staging.idposte__contrat (
    run_id          TEXT        NOT NULL,
    staged_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    cn_pg_id        BIGINT      NOT NULL,
    structure_tp_id BIGINT,
    date_debut      DATE,
    date_fin        DATE,
    date_rupture    DATE,
    type            TEXT
);
