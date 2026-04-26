--------------------------------------------------------------------------------
-- pkg_tb_auth: X-Narcis-Auth verification helper for the Terenska beležka
-- (TB_) ORDS handlers.
--
-- Same wire format and gate logic as the /app-auth/login handler
-- (tools/ords/auth_login.sql) - extracted into a package so the disturbance
-- CRUD endpoints can reuse it without duplicating PL/SQL.
--
-- Single failure mode: any auth failure raises e_unauthorized. Handlers
-- catch it and return HTTP 401 with the same generic message used by
-- /app-auth/login. No enumeration of failure causes - matches the
-- non-enumeration policy enforced server-side already.
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

  -- Reads X-Narcis-Auth from the current CGI env. Returns NULL if absent.
  -- Tries the canonical CGI form first, then the raw forms ORDS uses for
  -- custom headers (verified live: HTTP_X_NARCIS_AUTH is NOT populated for
  -- this custom header on this instance; X-NARCIS-AUTH is - see
  -- ARCHITECTURE.md §9.1).
  FUNCTION get_auth_header RETURN VARCHAR2;

  -- Authenticates the current request and returns the auth context.
  -- Reads the X-Narcis-Auth header from the CGI env automatically. Raises
  -- e_unauthorized for any failure (no header, malformed, bad creds,
  -- TERENSKA-BELEZNICA not granted, etc.).
  FUNCTION authenticate RETURN t_auth_ctx;
END pkg_tb_auth;
/

CREATE OR REPLACE PACKAGE BODY pkg_tb_auth AS

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

  FUNCTION authenticate RETURN t_auth_ctx IS
    l_hdr      VARCHAR2(4000);
    l_decoded  VARCHAR2(4000);
    l_sep      PLS_INTEGER;
    l_email    VARCHAR2(255);
    l_password VARCHAR2(255);
    l_ctx      t_auth_ctx;
    l_func_id  NUMBER;
  BEGIN
    l_hdr := get_auth_header;
    IF l_hdr IS NULL OR SUBSTR(l_hdr, 1, 6) <> 'Basic ' THEN
      RAISE e_unauthorized;
    END IF;

    BEGIN
      l_decoded := UTL_I18N.raw_to_char(
        UTL_ENCODE.base64_decode(UTL_RAW.cast_to_raw(SUBSTR(l_hdr, 7))),
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
      SELECT app_user, id, organizacija
        INTO l_ctx.app_user, l_ctx.user_id, l_ctx.org_id
        FROM narcis_uporabniki
       WHERE LOWER(TRIM(email)) = l_email;
    EXCEPTION
      WHEN NO_DATA_FOUND OR TOO_MANY_ROWS THEN RAISE e_unauthorized;
    END;

    IF l_ctx.app_user IS NULL OR l_ctx.org_id IS NULL THEN
      -- A user without an org cannot create disturbance records (no codebook
      -- scope, no place to file the row). Treated as unauthorized for
      -- consistency - same generic 401 as any other failure mode.
      RAISE e_unauthorized;
    END IF;

    BEGIN
      IF NOT pkg_narcis_uporabniki.preveri_geslo(
               p_username         => l_ctx.app_user,
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

    l_ctx.email := l_email;
    RETURN l_ctx;
  END authenticate;

END pkg_tb_auth;
/

SHOW ERRORS PACKAGE pkg_tb_auth
SHOW ERRORS PACKAGE BODY pkg_tb_auth
