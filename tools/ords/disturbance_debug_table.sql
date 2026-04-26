--------------------------------------------------------------------------------
-- TEMPORARY diagnostic table for the disturbance POST handler.
-- One row per POST request, written before the response goes out.
-- Mirrors the narcis_auth_debug pattern.
--
-- Drop after debugging:
--   DROP TABLE tb_motnje_debug PURGE;
--------------------------------------------------------------------------------

DECLARE
  e_already_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_already_exists, -955);
BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE tb_motnje_debug (
      id            NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      ts            TIMESTAMP DEFAULT SYSTIMESTAMP,
      runtime_user  VARCHAR2(40),
      step_reached  VARCHAR2(80),
      auth_email    VARCHAR2(255),
      auth_org_id   NUMBER,
      body_len      NUMBER,
      parsed_id     VARCHAR2(40),
      existing_cnt  NUMBER,
      err_msg       VARCHAR2(500),
      raw_body      CLOB
    )
  ~';
EXCEPTION
  WHEN e_already_exists THEN NULL;
END;
/
