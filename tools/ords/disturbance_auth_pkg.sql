--------------------------------------------------------------------------------
-- pkg_tb_auth: X-Narcis-Auth verification helper for the Terenska beležka
-- (TB_) ORDS handlers.
--
-- Accepts TWO credential schemes on the X-Narcis-Auth header:
--   * Basic  <base64(email:password)>  - validates email + password +
--     TERENSKA-BELEZNICA, exactly as /app-auth/login does. Kept for the login
--     mint step, the smoke-test scripts, and any older client still on Basic.
--   * Bearer <token>                    - validates an opaque session token
--     minted by mint_token (see auth_token_schema.sql). The token is hashed and
--     looked up in TB_AUTH_TOKENS; identity (email/app_user/org) and the
--     TERENSKA-BELEZNICA authorization are RE-DERIVED from NARCIS_UPORABNIKI on
--     every call, so revoking the function or moving the user's org takes
--     effect on the next request - same gate the Basic path enforces.
--
-- Single failure mode: any auth failure raises e_unauthorized. Handlers catch
-- it and return HTTP 401 with the same generic message used by /app-auth/login.
-- No enumeration of failure causes.
--
-- Dependency: DBMS_CRYPTO (RANDOMBYTES + HASH_SH256). The NARCIS schema needs
-- EXECUTE on SYS.DBMS_CRYPTO; pkg_narcis_uporabniki already hashes passwords so
-- the grant is expected to be present. If the body fails to compile with
-- PLS-00201 on DBMS_CRYPTO, run (as a privileged user):
--   GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <narcis_schema>;
--
-- Idempotent: CREATE OR REPLACE; safe to re-run.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE pkg_tb_auth AS
  -- Authentication context returned on success. ORG_ID is the user's
  -- organizacija FK from narcis_uporabniki - stamped onto every record
  -- the user creates so the per-org codebook scope is enforced server-side.
  TYPE t_auth_ctx IS RECORD (
    email     VARCHAR2(255),
    app_user  narcis_uporabniki.app_user%TYPE,
    user_id   narcis_uporabniki.id%TYPE,
    org_id    narcis_uporabniki.organizacija%TYPE
  );

  -- Single sentinel for any auth failure. Handlers catch this and emit 401.
  e_unauthorized EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_unauthorized, -20401);

  -- Session token lifetime. Sliding: each use within the window pushes
  -- EXPIRES_AT forward to now + this many days (renewal write is throttled,
  -- see c_renew_after_hours in the body).
  c_token_ttl_days CONSTANT PLS_INTEGER := 30;

  -- Reads X-Narcis-Auth from the current CGI env. Returns NULL if absent.
  -- Tries the canonical CGI form first, then the raw forms ORDS uses for
  -- custom headers (verified live: HTTP_X_NARCIS_AUTH is NOT populated for
  -- this custom header on this instance; X-NARCIS-AUTH is - see
  -- ARCHITECTURE.md §9.1).
  FUNCTION get_auth_header RETURN VARCHAR2;

  -- Authenticates the current request and returns the auth context. Reads the
  -- X-Narcis-Auth header from the CGI env automatically and dispatches on the
  -- scheme (Basic or Bearer). Raises e_unauthorized for any failure.
  FUNCTION authenticate RETURN t_auth_ctx;

  -- Mints a new opaque session token for an already-authenticated user.
  -- Returns the PLAINTEXT token (64 hex chars) to hand back to the client;
  -- only its SHA-256 hash is stored. Commits the new row itself so the token
  -- is durable before the caller returns it. Opportunistically purges the
  -- user's expired/revoked tokens. p_device_info is a free-text audit hint
  -- (e.g. the request User-Agent) shown to operators when revoking.
  FUNCTION mint_token(
    p_user_id     IN narcis_uporabniki.id%TYPE,
    p_device_info IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2;

  -- Revokes a token by its plaintext value (sets REVOKED_AT). No-op if the
  -- token is unknown or already revoked. Commits.
  PROCEDURE revoke_token(p_token IN VARCHAR2);
END pkg_tb_auth;
/

CREATE OR REPLACE PACKAGE BODY pkg_tb_auth AS

  -- Throttle for the sliding-expiry renewal write: only touch TB_AUTH_TOKENS
  -- when the token hasn't been used in this many hours. Keeps a busy client
  -- from issuing a DB write on every single CRUD call while still keeping the
  -- 30-day window sliding for any reasonably active user.
  c_renew_after_hours CONSTANT PLS_INTEGER := 24;

  FUNCTION get_auth_header RETURN VARCHAR2 IS
    l_hdr VARCHAR2(4000);
  BEGIN
    -- Same fallback chain as auth_login.sql: try canonical first, then raw.
    l_hdr := OWA_UTIL.get_cgi_env('HTTP_X_NARCIS_AUTH');
    IF l_hdr IS NULL THEN l_hdr := OWA_UTIL.get_cgi_env('HTTP_X-NARCIS-AUTH'); END IF;
    IF l_hdr IS NULL THEN l_hdr := OWA_UTIL.get_cgi_env('X-NARCIS-AUTH');     END IF;
    IF l_hdr IS NULL THEN l_hdr := OWA_UTIL.get_cgi_env('X_NARCIS_AUTH');     END IF;
    RETURN l_hdr;
  END get_auth_header;

  -- SHA-256 of the token's literal characters. mint and verify must agree;
  -- both hash the token string bytes (not HEXTORAW) so the scheme is opaque
  -- to the token's internal format.
  FUNCTION token_hash(p_token IN VARCHAR2) RETURN RAW IS
  BEGIN
    RETURN DBMS_CRYPTO.hash(
             UTL_RAW.cast_to_raw(p_token),
             DBMS_CRYPTO.hash_sh256
           );
  END token_hash;

  -- Re-derives the auth context for a known user_id and re-checks the
  -- TERENSKA-BELEZNICA authorization. Shared by the Bearer path (Basic derives
  -- inline because it looks the user up by email). Raises e_unauthorized on any
  -- failure (unknown user, no org, function not granted).
  FUNCTION ctx_for_user(p_user_id IN narcis_uporabniki.id%TYPE)
    RETURN t_auth_ctx IS
    l_ctx     t_auth_ctx;
    l_func_id NUMBER;
  BEGIN
    BEGIN
      SELECT LOWER(TRIM(email)), app_user, id, organizacija
        INTO l_ctx.email, l_ctx.app_user, l_ctx.user_id, l_ctx.org_id
        FROM narcis_uporabniki
       WHERE id = p_user_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RAISE e_unauthorized;
    END;

    IF l_ctx.app_user IS NULL OR l_ctx.org_id IS NULL THEN
      RAISE e_unauthorized;
    END IF;

    BEGIN
      l_func_id := pkg_narcis_authorization.get_id_funkc('TERENSKA-BELEZNICA');
      IF l_func_id IS NULL
         OR NOT pkg_narcis_authorization.has_function_by_id(
                  in_funkcionalnost_id => l_func_id,
                  in_app_user          => l_ctx.app_user
                )
      THEN
        RAISE e_unauthorized;
      END IF;
    EXCEPTION
      WHEN e_unauthorized THEN RAISE;
      WHEN OTHERS THEN RAISE e_unauthorized;
    END;

    RETURN l_ctx;
  END ctx_for_user;

  -- Sliding-expiry renewal, throttled and isolated. AUTONOMOUS_TRANSACTION so
  -- the renewal commits independently of the CRUD handler's transaction (which
  -- may be a non-committing GET, or may ROLLBACK in its WHEN OTHERS guard) -
  -- the token's freshness must not depend on whether the request's data work
  -- succeeds.
  PROCEDURE renew_token(p_hash IN RAW) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE tb_auth_tokens
       SET last_used_at = SYSTIMESTAMP,
           expires_at   = SYSTIMESTAMP + NUMTODSINTERVAL(c_token_ttl_days, 'DAY')
     WHERE token_hash = p_hash
       AND (last_used_at IS NULL
            OR last_used_at < SYSTIMESTAMP - NUMTODSINTERVAL(c_renew_after_hours, 'HOUR'));
    COMMIT;
  END renew_token;

  -- Basic <base64(email:password)> path. Unchanged gate logic: decode, look up
  -- by email, verify password, check TERENSKA-BELEZNICA.
  FUNCTION authenticate_basic(p_hdr IN VARCHAR2) RETURN t_auth_ctx IS
    l_decoded  VARCHAR2(4000);
    l_sep      PLS_INTEGER;
    l_email    VARCHAR2(255);
    l_password VARCHAR2(255);
    l_user_id  narcis_uporabniki.id%TYPE;
    l_app_user narcis_uporabniki.app_user%TYPE;
    l_ctx      t_auth_ctx;
  BEGIN
    BEGIN
      l_decoded := UTL_I18N.raw_to_char(
        UTL_ENCODE.base64_decode(UTL_RAW.cast_to_raw(SUBSTR(p_hdr, 7))),
        'AL32UTF8'
      );
    EXCEPTION
      WHEN OTHERS THEN RAISE e_unauthorized;
    END;

    l_sep := INSTR(l_decoded, ':');
    IF l_sep = 0 THEN RAISE e_unauthorized; END IF;

    l_email    := LOWER(TRIM(SUBSTR(l_decoded, 1, l_sep - 1)));
    l_password := SUBSTR(l_decoded, l_sep + 1);
    IF l_email IS NULL OR l_password IS NULL THEN RAISE e_unauthorized; END IF;

    BEGIN
      SELECT app_user, id
        INTO l_app_user, l_user_id
        FROM narcis_uporabniki
       WHERE LOWER(TRIM(email)) = l_email;
    EXCEPTION
      WHEN NO_DATA_FOUND OR TOO_MANY_ROWS THEN RAISE e_unauthorized;
    END;

    IF l_app_user IS NULL THEN RAISE e_unauthorized; END IF;

    BEGIN
      IF NOT pkg_narcis_uporabniki.preveri_geslo(
               p_username         => l_app_user,
               p_password         => l_password,
               p_check_complexity => FALSE
             )
      THEN
        RAISE e_unauthorized;
      END IF;
    EXCEPTION
      WHEN e_unauthorized THEN RAISE;
      WHEN OTHERS THEN RAISE e_unauthorized;
    END;

    -- Re-derive org + re-check TERENSKA-BELEZNICA via the shared helper.
    l_ctx := ctx_for_user(l_user_id);
    RETURN l_ctx;
  END authenticate_basic;

  -- Bearer <token> path. Hash, look up, check live, re-derive identity, renew.
  FUNCTION authenticate_bearer(p_token IN VARCHAR2) RETURN t_auth_ctx IS
    l_hash     RAW(32);
    l_user_id  narcis_uporabniki.id%TYPE;
    l_expires  TIMESTAMP;
    l_revoked  TIMESTAMP;
    l_ctx      t_auth_ctx;
  BEGIN
    IF p_token IS NULL OR LENGTH(p_token) = 0 THEN RAISE e_unauthorized; END IF;

    BEGIN
      l_hash := token_hash(p_token);
    EXCEPTION
      WHEN OTHERS THEN RAISE e_unauthorized;
    END;

    BEGIN
      SELECT user_id, expires_at, revoked_at
        INTO l_user_id, l_expires, l_revoked
        FROM tb_auth_tokens
       WHERE token_hash = l_hash;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RAISE e_unauthorized;
    END;

    IF l_revoked IS NOT NULL OR l_expires < SYSTIMESTAMP THEN
      RAISE e_unauthorized;
    END IF;

    -- Identity + authorization re-checked live (not snapshotted on the token).
    l_ctx := ctx_for_user(l_user_id);

    -- Slide the expiry forward (throttled, autonomous).
    renew_token(l_hash);

    RETURN l_ctx;
  END authenticate_bearer;

  FUNCTION authenticate RETURN t_auth_ctx IS
    l_hdr VARCHAR2(4000);
  BEGIN
    l_hdr := get_auth_header;
    IF l_hdr IS NULL THEN RAISE e_unauthorized; END IF;

    IF SUBSTR(l_hdr, 1, 7) = 'Bearer ' THEN
      RETURN authenticate_bearer(SUBSTR(l_hdr, 8));
    ELSIF SUBSTR(l_hdr, 1, 6) = 'Basic ' THEN
      RETURN authenticate_basic(l_hdr);
    ELSE
      RAISE e_unauthorized;
    END IF;
  END authenticate;

  FUNCTION mint_token(
    p_user_id     IN narcis_uporabniki.id%TYPE,
    p_device_info IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2 IS
    l_token VARCHAR2(64);
    l_hash  RAW(32);
  BEGIN
    -- 32 CSPRNG bytes -> 64 hex chars on the wire.
    l_token := RAWTOHEX(DBMS_CRYPTO.randombytes(32));
    l_hash  := token_hash(l_token);

    -- Bound table growth: drop this user's dead tokens as we add a fresh one.
    DELETE FROM tb_auth_tokens
     WHERE user_id = p_user_id
       AND (revoked_at IS NOT NULL OR expires_at < SYSTIMESTAMP);

    INSERT INTO tb_auth_tokens (
      token_hash, user_id, created_at, expires_at, device_info
    ) VALUES (
      l_hash,
      p_user_id,
      SYSTIMESTAMP,
      SYSTIMESTAMP + NUMTODSINTERVAL(c_token_ttl_days, 'DAY'),
      SUBSTR(p_device_info, 1, 400)
    );
    COMMIT;

    RETURN l_token;
  END mint_token;

  PROCEDURE revoke_token(p_token IN VARCHAR2) IS
    l_hash RAW(32);
  BEGIN
    IF p_token IS NULL OR LENGTH(p_token) = 0 THEN RETURN; END IF;
    BEGIN
      l_hash := token_hash(p_token);
    EXCEPTION
      WHEN OTHERS THEN RETURN;
    END;
    UPDATE tb_auth_tokens
       SET revoked_at = SYSTIMESTAMP
     WHERE token_hash = l_hash
       AND revoked_at IS NULL;
    COMMIT;
  END revoke_token;

END pkg_tb_auth;
/

SHOW ERRORS PACKAGE pkg_tb_auth
SHOW ERRORS PACKAGE BODY pkg_tb_auth
