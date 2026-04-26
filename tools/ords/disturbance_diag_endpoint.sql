--------------------------------------------------------------------------------
-- TEMPORARY diagnostic GET endpoint at /disturbances/_diag
-- Returns the schema the handler runs in and the count of tb_motnje it sees.
-- No auth (intentional - diagnosis only). Remove after debugging:
--
--   BEGIN
--     ORDS.DELETE_HANDLER(
--       p_module_name => 'narcis_disturbances',
--       p_pattern     => '_diag',
--       p_method      => 'GET');
--     COMMIT;
--   END;
--   /
--------------------------------------------------------------------------------

BEGIN
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_disturbances',
    p_pattern     => '_diag'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => '_diag',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_count_unqual NUMBER;
  l_count_narcis NUMBER;
  l_first_id     VARCHAR2(36);
  l_first_user   VARCHAR2(255);
  l_err_unqual   VARCHAR2(500) := NULL;
  l_err_narcis   VARCHAR2(500) := NULL;
BEGIN
  -- What does the handler resolve "tb_motnje" to right now?
  BEGIN
    SELECT COUNT(*) INTO l_count_unqual FROM tb_motnje;
  EXCEPTION
    WHEN OTHERS THEN
      l_count_unqual := -1;
      l_err_unqual := SQLERRM;
  END;

  -- Force the NARCIS-qualified path to compare.
  BEGIN
    SELECT COUNT(*) INTO l_count_narcis FROM narcis.tb_motnje;
  EXCEPTION
    WHEN OTHERS THEN
      l_count_narcis := -1;
      l_err_narcis := SQLERRM;
  END;

  -- Most recent row the handler can see (if any).
  BEGIN
    SELECT motnja_id, ustvarjen_od INTO l_first_id, l_first_user
      FROM (SELECT motnja_id, ustvarjen_od
              FROM tb_motnje
             ORDER BY ustvarjen DESC)
     WHERE ROWNUM = 1;
  EXCEPTION
    WHEN OTHERS THEN
      l_first_id := NULL;
  END;

  :status_code  := 200;
  :content_type := 'application/json';
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('runtime_user', USER);
  APEX_JSON.write('tb_motnje_count_unqualified', l_count_unqual);
  APEX_JSON.write('tb_motnje_count_narcis', l_count_narcis);
  APEX_JSON.write('err_unqualified', l_err_unqual);
  APEX_JSON.write('err_narcis', l_err_narcis);
  APEX_JSON.write('most_recent_id', l_first_id);
  APEX_JSON.write('most_recent_user', l_first_user);
  APEX_JSON.close_object;
  HTP.prn(APEX_JSON.get_clob_output);
  APEX_JSON.free_output;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '_diag',
    p_method => 'GET', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '_diag',
    p_method => 'GET', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  COMMIT;
END;
/
