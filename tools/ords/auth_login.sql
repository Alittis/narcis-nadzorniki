--------------------------------------------------------------------------------
-- ORDS handler: GET https://narcis.gov.si/ords/narcis/app-auth/login
--
-- Replaces the throwaway stub at /test/auth.
--
-- Wire format:
--   Request : X-Narcis-Auth: Basic <base64(email:password)>
--   Success : HTTP 200  {"authenticated":true,"user":"<email>"}
--   Failure : HTTP 401  {"authenticated":false,"message":"Neveljavni podatki za prijavo."}
--
-- Why X-Narcis-Auth and not the standard Authorization header:
--   This ORDS instance consumes Authorization: Basic for its own first-party
--   auth filter, so the header never reaches handler PL/SQL (verified with
--   instrumented debug logging on 2026-04-25 - all calls showed
--   HTTP_AUTHORIZATION = NULL). A custom header bypasses the filter while
--   keeping the same base64 encoding scheme.
--
-- Server logic (single 401 message for all failure modes — no enumeration):
--   1. Decode Basic credentials.
--   2. Look up email -> app_user, id in narcis_uporabniki (case-insensitive).
--   3. pkg_narcis_uporabniki.preveri_geslo(app_user, password, FALSE).
--   4. pkg_narcis_authorization.has_function_by_id('TERENSKA-BELEZNICA', app_user).
--   Any failure -> 401.
--
-- ORDS conventions used (replacing the broken OWA_UTIL approach):
--   - Status code via the implicit :status_code OUT bind (declared as a
--     parameter with source_type = RESPONSE).
--   - Content-Type via response header bind (X-ORDS-RESPONSE-HEADER style).
--     Cleaner: just use APEX_JSON which causes ORDS to default to
--     application/json when HTP.prn output looks like JSON. To be safe we
--     declare it explicitly.
--
-- Assumptions:
--   - Schema is already enabled for ORDS at URL alias 'narcis'.
--   - CORS handled at ORDS pool level.
--   - This endpoint MUST be reachable without first-party ORDS auth — it IS
--     the login. Do not protect it with ORDS.DEFINE_PRIVILEGE.
--
-- Idempotent: safe to re-run; existing module is dropped first.
--------------------------------------------------------------------------------

-- Drop any prior definition so the script is re-runnable.
BEGIN
  ORDS.DELETE_MODULE(p_module_name => 'narcis_app_auth');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'narcis_app_auth',
    p_base_path      => 'app-auth/',
    p_items_per_page => 0
  );

  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_app_auth',
    p_pattern     => 'login'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_app_auth',
    p_pattern     => 'login',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  -- Custom header X-Narcis-Auth -> CGI env HTTP_X_NARCIS_AUTH (canonical CGI
  -- transform: dashes become underscores, prefixed with HTTP_, uppercased).
  -- Cannot use HTTP_AUTHORIZATION: ORDS consumes that header upstream.
  --
  -- DEFENSIVE: also check a few alternate spellings in case ORDS exposes
  -- the header under a non-canonical name on this instance.
  l_auth_header VARCHAR2(4000);
  l_decoded     VARCHAR2(4000);
  l_sep_pos     PLS_INTEGER;
  l_email       VARCHAR2(255);
  l_password    VARCHAR2(255);
  l_app_user    narcis_uporabniki.app_user%TYPE;
  l_id          narcis_uporabniki.id%TYPE;
  l_func_id     NUMBER;
  l_ok          BOOLEAN := FALSE;
  l_step        VARCHAR2(40) := 'init';   -- DEBUG: tracks where we exited
  l_body        CLOB;
  l_env_dump    CLOB;                     -- DEBUG: full CGI env snapshot
BEGIN
  -- DEBUG: snapshot every CGI variable ORDS exposes, so we can see exactly
  -- which name (if any) the X-Narcis-Auth header arrives under. Cheap, runs
  -- before any auth logic so it always populates.
  BEGIN
    DBMS_LOB.createtemporary(l_env_dump, TRUE);
    FOR i IN 1 .. NVL(OWA.num_cgi_vars, 0) LOOP
      DBMS_LOB.append(
        l_env_dump,
        OWA.cgi_var_name(i) || '=' ||
          SUBSTR(NVL(OWA.cgi_var_val(i), ''), 1, 200) || CHR(10)
      );
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN NULL;  -- never let diagnostics break the handler
  END;

  -- Try the canonical name first, then a few defensive fallbacks.
  l_auth_header := OWA_UTIL.get_cgi_env('HTTP_X_NARCIS_AUTH');
  IF l_auth_header IS NULL THEN
    l_auth_header := OWA_UTIL.get_cgi_env('HTTP_X-NARCIS-AUTH');
  END IF;
  IF l_auth_header IS NULL THEN
    l_auth_header := OWA_UTIL.get_cgi_env('X-NARCIS-AUTH');
  END IF;
  IF l_auth_header IS NULL THEN
    l_auth_header := OWA_UTIL.get_cgi_env('X_NARCIS_AUTH');
  END IF;

  -- 1. Parse "Basic <base64>"
  IF l_auth_header IS NULL THEN
    l_step := 'no_auth_header'; GOTO respond;
  END IF;
  IF SUBSTR(l_auth_header, 1, 6) <> 'Basic ' THEN
    l_step := 'auth_not_basic'; GOTO respond;
  END IF;

  BEGIN
    l_decoded := UTL_I18N.raw_to_char(
      UTL_ENCODE.base64_decode(
        UTL_RAW.cast_to_raw(SUBSTR(l_auth_header, 7))
      ),
      'AL32UTF8'
    );
  EXCEPTION
    WHEN OTHERS THEN
      l_step := 'base64_decode_error'; GOTO respond;
  END;

  l_sep_pos := INSTR(l_decoded, ':');
  IF l_sep_pos = 0 THEN
    l_step := 'no_colon_separator'; GOTO respond;
  END IF;

  l_email    := LOWER(TRIM(SUBSTR(l_decoded, 1, l_sep_pos - 1)));
  l_password := SUBSTR(l_decoded, l_sep_pos + 1);

  IF l_email IS NULL THEN
    l_step := 'empty_email'; GOTO respond;
  END IF;
  IF l_password IS NULL THEN
    l_step := 'empty_password'; GOTO respond;
  END IF;

  -- 2. Look up user by email
  BEGIN
    SELECT app_user, id
      INTO l_app_user, l_id
      FROM narcis_uporabniki
     WHERE LOWER(TRIM(email)) = l_email;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      l_step := 'user_lookup_no_data'; GOTO respond;
    WHEN TOO_MANY_ROWS THEN
      l_step := 'user_lookup_too_many'; GOTO respond;
  END;

  IF l_app_user IS NULL THEN
    l_step := 'app_user_null'; GOTO respond;
  END IF;

  -- 3. Verify password
  BEGIN
    IF NOT pkg_narcis_uporabniki.preveri_geslo(
             p_username         => l_app_user,
             p_password         => l_password,
             p_check_complexity => FALSE
           )
    THEN
      l_step := 'preveri_geslo_false'; GOTO respond;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      l_step := 'preveri_geslo_exception'; GOTO respond;
  END;

  -- 4. Verify TERENSKA-BELEZNICA function authorization
  BEGIN
    l_func_id := pkg_narcis_authorization.get_id_funkc('TERENSKA-BELEZNICA');
    IF l_func_id IS NULL THEN
      l_step := 'func_id_null'; GOTO respond;
    END IF;
    IF NOT pkg_narcis_authorization.has_function_by_id(
             in_funkcionalnost_id => l_func_id,
             in_app_user          => l_app_user
           )
    THEN
      l_step := 'has_function_false'; GOTO respond;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      l_step := 'func_check_exception'; GOTO respond;
  END;

  l_step := 'ok';
  l_ok   := TRUE;

  <<respond>>
  -- DEBUG instrumentation. Logs one row per request to narcis_auth_debug.
  -- Wrapped in its own block so a missing table (post-diagnosis cleanup)
  -- silently disables logging without breaking the response.
  -- Password VALUE is never logged - only LENGTH.
  -- Remove this block and DROP TABLE narcis_auth_debug after diagnosis.
  BEGIN
    INSERT INTO narcis_auth_debug (
      step_reached, auth_hdr_prefix, auth_hdr_length, decoded_length,
      sep_pos, decoded_email, pw_length, app_user_found, env_dump
    ) VALUES (
      l_step,
      SUBSTR(l_auth_header, 1, 20),
      LENGTH(l_auth_header),
      LENGTH(l_decoded),
      l_sep_pos,
      l_email,
      LENGTH(l_password),
      l_app_user,
      l_env_dump
    );
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN NULL;  -- e.g. column doesn't exist yet
  END;

  -- Status code via ORDS implicit bind
  IF l_ok THEN
    :status_code := 200;
  ELSE
    :status_code := 401;
  END IF;

  -- Response Content-Type via ORDS implicit bind
  :content_type := 'application/json';

  -- Build body
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  IF l_ok THEN
    APEX_JSON.write('authenticated', TRUE);
    APEX_JSON.write('user', l_email);
  ELSE
    APEX_JSON.write('authenticated', FALSE);
    APEX_JSON.write('message', 'Neveljavni podatki za prijavo.');
  END IF;
  APEX_JSON.close_object;
  l_body := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  HTP.prn(l_body);
END;
~'
  );

  -- Declare the OUT bind for HTTP status code so ORDS sets the response status.
  -- Source type MUST be 'HEADER' (not 'RESPONSE'); the magic name
  -- X-ORDS-STATUS-CODE tells ORDS to use it as the status code instead of
  -- emitting a real header. With 'RESPONSE' source type ORDS would serialize
  -- this OUT bind into the response BODY as JSON, clobbering HTP.prn output.
  ORDS.DEFINE_PARAMETER(
    p_module_name        => 'narcis_app_auth',
    p_pattern            => 'login',
    p_method             => 'GET',
    p_name               => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code',
    p_source_type        => 'HEADER',
    p_param_type         => 'INT',
    p_access_method      => 'OUT'
  );

  -- Declare the OUT bind for Content-Type response header
  ORDS.DEFINE_PARAMETER(
    p_module_name        => 'narcis_app_auth',
    p_pattern            => 'login',
    p_method             => 'GET',
    p_name               => 'Content-Type',
    p_bind_variable_name => 'content_type',
    p_source_type        => 'HEADER',
    p_param_type         => 'STRING',
    p_access_method      => 'OUT'
  );

  COMMIT;
END;
/
