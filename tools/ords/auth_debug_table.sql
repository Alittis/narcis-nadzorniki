--------------------------------------------------------------------------------
-- Diagnostic table for the /app-auth/login handler.
--
-- Idempotent: re-runnable. Creates the table if missing, adds env_dump
-- column if not present.
--
-- DROP TABLE narcis_auth_debug PURGE;  -- run after diagnosis is done.
--
-- APEX SQL Commands compatible: each statement standalone, no SQL*Plus
-- directives.
--------------------------------------------------------------------------------

-- 1. Create the debug table (no-op if it already exists).
DECLARE
  e_already_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_already_exists, -955);  -- ORA-00955
BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE narcis_auth_debug (
      id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      ts              TIMESTAMP DEFAULT SYSTIMESTAMP,
      step_reached    VARCHAR2(40),
      auth_hdr_prefix VARCHAR2(40),
      auth_hdr_length NUMBER,
      decoded_length  NUMBER,
      sep_pos         NUMBER,
      decoded_email   VARCHAR2(255),
      pw_length       NUMBER,
      app_user_found  VARCHAR2(255)
    )
  ~';
EXCEPTION
  WHEN e_already_exists THEN NULL;
END;
/

-- 2. Add env_dump column (no-op if it already exists).
DECLARE
  e_column_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_column_exists, -1430);  -- ORA-01430
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE narcis_auth_debug ADD (env_dump CLOB)';
EXCEPTION
  WHEN e_column_exists THEN NULL;
END;
/
