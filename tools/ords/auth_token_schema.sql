--------------------------------------------------------------------------------
-- Bearer-token store for the "Terenska beležka" (TB_) app authentication.
--
-- TB_AUTH_TOKENS holds opaque session tokens minted by /app-auth/login and
-- accepted by pkg_tb_auth.authenticate as `X-Narcis-Auth: Bearer <token>` on
-- every disturbance/walk CRUD call. This replaces sending the user's plaintext
-- password on every request - the password is now sent exactly once, at login.
--
-- Security model:
--   * Only the SHA-256 HASH of the token is stored (TOKEN_HASH). The plaintext
--     token is returned to the client exactly once, at mint time, and is never
--     persisted server-side - a DB leak therefore yields no usable tokens.
--   * Identity is NOT snapshotted: USER_ID is the only identity column. Email,
--     app_user, org_id and the TERENSKA-BELEZNICA authorization are re-derived
--     from NARCIS_UPORABNIKI on every call, so revoking the function (or moving
--     the user's organizacija) takes effect on the next request - exactly the
--     same gate the Basic-auth path enforces today.
--   * Sliding 30-day expiry: EXPIRES_AT is bumped forward on use (the renewal
--     write is throttled in pkg_tb_auth so it is not a write per call).
--     REVOKED_AT is set on logout / operator revoke; NULL means active.
--
-- Housekeeping: pkg_tb_auth.mint_token opportunistically deletes the minting
-- user's expired/revoked rows, so table growth is bounded without a scheduler.
--
-- Operator revoke (e.g. lost device):
--   UPDATE tb_auth_tokens SET revoked_at = SYSTIMESTAMP
--    WHERE user_id = (SELECT id FROM narcis_uporabniki WHERE LOWER(TRIM(email)) = '<email>')
--      AND revoked_at IS NULL;
--   COMMIT;
--
-- Idempotent: the CREATE is wrapped in a guard so the script can be re-run.
--   Clean rebuild:  DROP TABLE TB_AUTH_TOKENS PURGE;
--------------------------------------------------------------------------------

DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_AUTH_TOKENS';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_auth_tokens (
        token_hash    RAW(32)        NOT NULL,
        user_id       NUMBER         NOT NULL,
        created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
        expires_at    TIMESTAMP      NOT NULL,
        last_used_at  TIMESTAMP      NULL,
        revoked_at    TIMESTAMP      NULL,
        device_info   VARCHAR2(400)  NULL,
        CONSTRAINT pk_tb_auth_tokens      PRIMARY KEY (token_hash),
        CONSTRAINT fk_tb_auth_tokens_usr  FOREIGN KEY (user_id)
                                          REFERENCES narcis_uporabniki (id)
                                          ON DELETE CASCADE
      )
    ~';
    -- Listing / bulk-revoking all of a user's tokens, and the opportunistic
    -- purge in mint_token, both filter by user_id.
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_auth_tokens_user ON tb_auth_tokens (user_id)';
    -- Makes an expiry-driven purge cheap if a scheduled cleanup is added later.
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_auth_tokens_exp  ON tb_auth_tokens (expires_at)';
  END IF;
END;
/

COMMIT;
