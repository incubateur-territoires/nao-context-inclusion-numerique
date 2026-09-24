-- V117 — Rotation des tokens API : fonction auth.rotate_token + fix de l'exp de create_jwt
--
-- Contexte (cf. docs/POSTGREST.md §Authentification JWT) :
--   1. BUG exp : auth.create_jwt déclarait son paramètre expiration_date en `date`.
--      create_role_n_token (V036) lui passe pourtant un timestamp
--      'YYYY-MM-DD 23:59:59.999999' -> cast implicite en `date` -> 'YYYY-MM-DD' ->
--      extract(epoch ...) = minuit. Conséquence : le claim `exp` du JWT tombait à
--      minuit (≈ 24 h trop tôt) alors que auth.token.expiration_date affichait
--      23:59:59. C'est ce qui a fait expirer get_mediateur (postgrest_coop) et les
--      autres tokens 2026S1 dès le matin du 2026-06-30.
--   2. Pas d'outil de rotation automatisable : create_role_n_token émet le JWT via
--      RAISE NOTICE (donc en logs PG, en clair) et ne le retourne pas.
--
-- Cette migration :
--   1. corrige auth.create_jwt (date -> timestamp), exp à la seconde
--   2. ajoute auth.rotate_token() : régénère un JWT pour un rôle EXISTANT, l'enregistre
--      dans auth.token en active=true SANS révoquer l'ancien (fenêtre de recouvrement),
--      et RETOURNE le JWT (aucun RAISE NOTICE -> rien en logs).
--
-- Ne touche pas le schéma api -> pas de NOTIFY pgrst nécessaire.

-- 1. Fix create_jwt : timestamp au lieu de date (exp à la seconde)
DROP FUNCTION IF EXISTS auth.create_jwt(varchar, varchar, date, text);

CREATE OR REPLACE FUNCTION auth.create_jwt(token_id varchar(50), username varchar(50), expiration_date timestamp, secret text) RETURNS text AS $$
  SELECT auth.sign(
    row_to_json(r), secret
  ) AS token
  FROM (
    SELECT
      token_id AS jti,
      username::text as aud,
      extract(epoch from expiration_date)::integer AS exp
  ) r;
$$ LANGUAGE sql;

COMMENT ON FUNCTION auth.create_jwt IS 'Génère un JWT signé HS256 (jti, aud, exp). exp à la seconde (param timestamp depuis V117).';

-- 2. Rotation d'un token pour un rôle existant (overlap : l'ancien reste actif)
CREATE OR REPLACE FUNCTION auth.rotate_token(
    p_role          varchar(50),
    p_new_token_id  varchar(50),
    p_secret        text,
    p_expiration    timestamp,
    p_comment       varchar(255) DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_jwt text;
BEGIN
    -- Rotation uniquement : le rôle doit déjà exister
    -- (pour un nouveau consommateur, utiliser auth.create_role_n_token).
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'Rôle "%" inexistant — utiliser auth.create_role_n_token pour un nouveau consommateur.', p_role;
    END IF;

    -- token_id unique (le claim jti doit être nouveau)
    IF EXISTS (SELECT 1 FROM auth.token WHERE token_id = p_new_token_id) THEN
        RAISE EXCEPTION 'token_id "%" déjà présent dans auth.token.', p_new_token_id;
    END IF;

    -- Génère le JWT avec exp à la seconde
    SELECT auth.sign(row_to_json(r), p_secret)
    INTO v_jwt
    FROM (
        SELECT p_new_token_id AS jti,
               p_role::text   AS aud,
               extract(epoch from p_expiration)::integer AS exp
    ) r;

    -- Enregistre le nouveau token, actif. L'ancien n'est PAS révoqué -> overlap,
    -- le consommateur bascule quand il veut, puis on désactive l'ancien (active=false).
    INSERT INTO auth.token (token_id, pg_role, expiration_date, comment, active)
    VALUES (p_new_token_id, p_role, p_expiration, p_comment, true);

    RETURN v_jwt;
END;
$function$;

COMMENT ON FUNCTION auth.rotate_token IS 'Rotation d''un JWT pour un rôle existant : exp à la seconde, enregistré actif sans révoquer l''ancien (fenêtre de recouvrement). Retourne le JWT. N''écrit rien en logs.';
