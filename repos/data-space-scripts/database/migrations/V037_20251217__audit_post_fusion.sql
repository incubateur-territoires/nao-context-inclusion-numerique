CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.structure_merge_log (
  id                 bigserial PRIMARY KEY,
  merged_at          timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL CHECK (status IN ('SUCCESS', 'FAILURE')),
  dag_id             text        NULL,
  run_id             text        NULL,
  task_id            text        NULL,
  map_index          integer     NULL,
  try_number         integer     NULL,

  winner_id          integer     NOT NULL,
  loser_id           integer     NOT NULL,
  similarity_score   numeric     NULL,
  similarity_threshold numeric   NULL,

  winner_before      jsonb       NULL,
  loser_before       jsonb       NULL,
  winner_after       jsonb       NULL,

  moved_identifiers  jsonb       NULL,
  error_message      text        NULL
);

CREATE INDEX IF NOT EXISTS structure_merge_log_winner_idx
  ON audit.structure_merge_log (winner_id);

CREATE INDEX IF NOT EXISTS structure_merge_log_loser_idx
  ON audit.structure_merge_log (loser_id);

CREATE INDEX IF NOT EXISTS structure_merge_log_merged_at_idx
  ON audit.structure_merge_log (merged_at);

CREATE INDEX IF NOT EXISTS structure_merge_log_run_idx
  ON audit.structure_merge_log (run_id);



CREATE TABLE audit.personne_merge_log (
  id bigserial PRIMARY KEY,
  merged_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL CHECK (status IN ('SUCCESS', 'FAILURE')),

  -- Airflow context (for traceability)
  dag_id text NULL,
  run_id text NULL,
  task_id text NULL,
  map_index integer NULL,
  try_number integer NULL,

  winner_id integer NOT NULL,
  loser_id integer NOT NULL,

  -- Similarity
  similarity_score numeric NULL,
  similarity_threshold numeric NULL,

  winner_before jsonb NULL,
  loser_before jsonb NULL,
  winner_after jsonb NULL,

  moved_identifiers jsonb NULL,

  error_message text NULL
);

CREATE INDEX IF NOT EXISTS personne_merge_log_merged_at_idx
  ON audit.personne_merge_log (merged_at);

CREATE INDEX IF NOT EXISTS personne_merge_log_winner_idx
  ON audit.personne_merge_log (winner_id);

CREATE INDEX IF NOT EXISTS personne_merge_log_loser_idx
  ON audit.personne_merge_log (loser_id);

CREATE INDEX IF NOT EXISTS personne_merge_log_run_idx
  ON audit.personne_merge_log (run_id);
