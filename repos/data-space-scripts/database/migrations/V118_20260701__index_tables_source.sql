-- Index sur les tables du schéma source pour accélérer les requêtes
-- d'audit (par run_id) et temporelles (par ingested_at).

CREATE INDEX idx_idposte__conum_run_id ON source.idposte__conum (run_id);
CREATE INDEX idx_idposte__conum_ingested_at ON source.idposte__conum (ingested_at);

CREATE INDEX idx_coop__structures_run_id ON source.coop__structures (run_id);
CREATE INDEX idx_coop__structures_ingested_at ON source.coop__structures (ingested_at);

CREATE INDEX idx_coop__utilisateurs_run_id ON source.coop__utilisateurs (run_id);
CREATE INDEX idx_coop__utilisateurs_ingested_at ON source.coop__utilisateurs (ingested_at);

CREATE INDEX idx_coop__activites_run_id ON source.coop__activites (run_id);
CREATE INDEX idx_coop__activites_ingested_at ON source.coop__activites (ingested_at);

CREATE INDEX idx_ac__structures_run_id ON source.ac__structures (run_id);
CREATE INDEX idx_ac__structures_ingested_at ON source.ac__structures (ingested_at);

CREATE INDEX idx_ac__aidants_run_id ON source.ac__aidants (run_id);
CREATE INDEX idx_ac__aidants_ingested_at ON source.ac__aidants (ingested_at);

CREATE INDEX idx_frr__zonage_run_id ON source.frr__zonage (run_id);
CREATE INDEX idx_frr__zonage_ingested_at ON source.frr__zonage (ingested_at);

CREATE INDEX idx_qpv__zonage_run_id ON source.qpv__zonage (run_id);
CREATE INDEX idx_qpv__zonage_ingested_at ON source.qpv__zonage (ingested_at);

CREATE INDEX idx_carto__structures_run_id ON source.carto__structures (run_id);
CREATE INDEX idx_carto__structures_ingested_at ON source.carto__structures (ingested_at);

CREATE INDEX idx_sirene__etablissements_run_id ON source.sirene__etablissements (run_id);
CREATE INDEX idx_sirene__etablissements_ingested_at ON source.sirene__etablissements (ingested_at);

CREATE INDEX idx_ban__adresses_run_id ON source.ban__adresses (run_id);
CREATE INDEX idx_ban__adresses_ingested_at ON source.ban__adresses (ingested_at);
