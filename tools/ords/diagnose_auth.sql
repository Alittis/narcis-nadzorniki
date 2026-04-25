--------------------------------------------------------------------------------
-- Diagnostic: trace the auth chain for a single email/password.
--
-- Bypasses ORDS entirely and calls the same three checks the
-- /app-auth/login handler does, printing which one fails.
--
-- Usage (SQLcl or SQL*Plus, connected as the schema owner of
-- narcis_uporabniki / pkg_narcis_uporabniki / pkg_narcis_authorization):
--
--   SQL> @tools/ords/diagnose_auth.sql
--   Email: alexis.zrimec@gov.si
--   Password: ********    <- input is hidden by ACCEPT ... HIDE
--
-- Use a test password that does NOT contain a single quote (the script
-- substitutes the password literally into PL/SQL; quotes will break parsing).
-- For SQL Developer users without ACCEPT support, hardcode c_email / c_password
-- in the DECLARE block below and remove the ACCEPT lines.
--
-- This script does not write to any table, does not log credentials anywhere,
-- and the password substitution is local to the SQL session.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF

ACCEPT email    CHAR PROMPT 'Email   : '
ACCEPT password CHAR PROMPT 'Password: ' HIDE

DECLARE
  c_email    CONSTANT VARCHAR2(255) := '&email';
  c_password CONSTANT VARCHAR2(255) := '&password';

  l_email_norm VARCHAR2(255);
  l_app_user   narcis_uporabniki.app_user%TYPE;
  l_id         narcis_uporabniki.id%TYPE;
  l_pw_ok      BOOLEAN;
  l_func_id    NUMBER;
  l_func_ok    BOOLEAN;
  l_match_cnt  PLS_INTEGER;
BEGIN
  l_email_norm := LOWER(TRIM(c_email));
  DBMS_OUTPUT.put_line('Diagnosing auth chain for: ' || l_email_norm);
  DBMS_OUTPUT.put_line('Password length         : ' || LENGTH(c_password) || ' chars');
  DBMS_OUTPUT.put_line('---------------------------------------------------------');

  -- STEP 1: email -> app_user lookup (case- and whitespace-insensitive)
  BEGIN
    SELECT app_user, id
      INTO l_app_user, l_id
      FROM narcis_uporabniki
     WHERE LOWER(TRIM(email)) = l_email_norm;

    IF l_app_user IS NULL THEN
      DBMS_OUTPUT.put_line('STEP 1  email lookup     : FAIL - app_user is NULL for this row');
      RETURN;
    END IF;
    DBMS_OUTPUT.put_line('STEP 1  email lookup     : OK     app_user=' || l_app_user
                         || '  id=' || l_id);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Cross-check: maybe the column has different case/whitespace conventions.
      SELECT COUNT(*) INTO l_match_cnt
        FROM narcis_uporabniki
       WHERE UPPER(email) = UPPER(c_email);
      DBMS_OUTPUT.put_line('STEP 1  email lookup     : FAIL - no row matches LOWER(TRIM(email)) = "'
                           || l_email_norm || '"');
      DBMS_OUTPUT.put_line('         (UPPER comparison finds ' || l_match_cnt || ' row(s))');
      RETURN;
    WHEN TOO_MANY_ROWS THEN
      DBMS_OUTPUT.put_line('STEP 1  email lookup     : FAIL - multiple rows match');
      RETURN;
  END;

  -- STEP 2: password verification via preveri_geslo
  BEGIN
    l_pw_ok := pkg_narcis_uporabniki.preveri_geslo(
                 p_username         => l_app_user,
                 p_password         => c_password,
                 p_check_complexity => FALSE
               );
    IF l_pw_ok IS NULL THEN
      DBMS_OUTPUT.put_line('STEP 2  preveri_geslo    : FAIL - returned NULL (handler treats as failure)');
      RETURN;
    ELSIF l_pw_ok THEN
      DBMS_OUTPUT.put_line('STEP 2  preveri_geslo    : OK     password matches stored credential');
    ELSE
      DBMS_OUTPUT.put_line('STEP 2  preveri_geslo    : FAIL - returned FALSE for this password');
      DBMS_OUTPUT.put_line('         (typo? account locked? different hash scheme expected?)');
      RETURN;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.put_line('STEP 2  preveri_geslo    : EXCEPTION - ' || SQLERRM);
      RETURN;
  END;

  -- STEP 3a: resolve TERENSKA-BELEZNICA function id
  BEGIN
    l_func_id := pkg_narcis_authorization.get_id_funkc('TERENSKA-BELEZNICA');
    IF l_func_id IS NULL THEN
      DBMS_OUTPUT.put_line('STEP 3a get_id_funkc     : FAIL - returned NULL '
                           || '(function "TERENSKA-BELEZNICA" not registered)');
      RETURN;
    END IF;
    DBMS_OUTPUT.put_line('STEP 3a get_id_funkc     : OK     id=' || l_func_id);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.put_line('STEP 3a get_id_funkc     : EXCEPTION - ' || SQLERRM);
      RETURN;
  END;

  -- STEP 3b: has_function_by_id check
  BEGIN
    l_func_ok := pkg_narcis_authorization.has_function_by_id(
                   in_funkcionalnost_id => l_func_id,
                   in_app_user          => l_app_user
                 );
    IF l_func_ok IS NULL THEN
      DBMS_OUTPUT.put_line('STEP 3b has_function     : FAIL - returned NULL');
      RETURN;
    ELSIF l_func_ok THEN
      DBMS_OUTPUT.put_line('STEP 3b has_function     : OK     user has TERENSKA-BELEZNICA');
    ELSE
      DBMS_OUTPUT.put_line('STEP 3b has_function     : FAIL - user does NOT have TERENSKA-BELEZNICA');
      RETURN;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.put_line('STEP 3b has_function     : EXCEPTION - ' || SQLERRM);
      RETURN;
  END;

  DBMS_OUTPUT.put_line('---------------------------------------------------------');
  DBMS_OUTPUT.put_line('All checks passed. This user SHOULD log in successfully.');
  DBMS_OUTPUT.put_line('If the live endpoint still returns 401 with these creds,');
  DBMS_OUTPUT.put_line('the bug is in the ORDS handler PL/SQL (likely base64 decode');
  DBMS_OUTPUT.put_line('or charset handling).');
END;
/

UNDEFINE email
UNDEFINE password
SET VERIFY ON
