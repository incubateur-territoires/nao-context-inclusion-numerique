ALTER TABLE main.coordination_mediation DROP COLUMN en_cours;
ALTER TABLE main.coordination_mediation ADD COLUMN suppression TIMESTAMP WITH TIME ZONE;

CREATE UNIQUE INDEX coordination_mediation_ukey
ON main.coordination_mediation (
  coordinateur_id,
  mediateur_id,
  (COALESCE(suppression, '1234-01-02 03:04:05+00'::timestamptz))
);

-- Commentaires :
COMMENT ON COLUMN main.coordination_mediation.suppression
    IS 'Date de suppression de la coordination médiation (NULL si en cours).';
