ALTER TABLE auth.token ADD COLUMN expiration_date timestamp without time zone DEFAULT NULL;

UPDATE auth.token SET expiration_date = '2025-12-31' WHERE token_id = 'anct-carto-001';
UPDATE auth.token SET expiration_date = '2025-12-31' WHERE token_id = 'anct-dev-test-001';
UPDATE auth.token SET expiration_date = '2026-06-30' WHERE token_id = 'anct-incub-001';
UPDATE auth.token SET expiration_date = '2026-06-30' WHERE token_id = 'anct-incub-002';
UPDATE auth.token SET expiration_date = '2025-12-31' WHERE token_id = 'anct-coop-001';
UPDATE auth.token SET expiration_date = '2025-08-31' WHERE token_id = 'lyon-test-001';
UPDATE auth.token SET expiration_date = '1970-01-01' WHERE expiration_date IS NULL;

ALTER TABLE auth.token ALTER COLUMN expiration_date SET NOT NULL;

UPDATE auth.token SET active = False WHERE expiration_date < now();

CREATE VIEW dataviz.tokens AS
    SELECT token_id, pg_role, comment, expiration_date, active, created_at, updated_at 
    FROM auth.token 
    ORDER BY pg_role, created_at;

-- Tokens à renouveler (expirants dans 30 jours et n'ayant pas été renouvelés)
CREATE VIEW dataviz.tokens_to_renew AS
    SELECT token_id, pg_role, comment, expiration_date, active, created_at, updated_at 
    FROM auth.token 
    WHERE expiration_date < now() + '30 days'::interval
    AND NOT EXISTS (SELECT 1 FROM auth.token AS new_tkn WHERE new_tkn.active IS TRUE AND new_tkn.expiration_date > now() + '30 days'::interval AND new_tkn.pg_role = token.pg_role)
    ORDER BY pg_role, created_at;

-- Send notification to PostgREST to reload the API schema
NOTIFY pgrst, 'reload schema';
