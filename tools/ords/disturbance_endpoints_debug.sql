--------------------------------------------------------------------------------
-- TEMPORARY: redeploys the narcis_disturbances ORDS module with the POST
-- handler instrumented to log every request to tb_motnje_debug via an
-- autonomous transaction. PUT and DELETE are unchanged.
--
-- Requires tb_motnje_debug to exist (run disturbance_debug_table.sql first).
--
-- After diagnosis, re-run tools/ords/disturbance_endpoints.sql to restore
-- the un-instrumented handler.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DELETE_MODULE(p_module_name => 'narcis_disturbances');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'narcis_disturbances',
    p_base_path      => 'disturbances/',
    p_items_per_page => 0
  );

  ----------------------------------------------------------------------------
  -- POST disturbances/   (INSTRUMENTED)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_disturbances',
    p_pattern     => '/'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => '/',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_body         CLOB := :body_text;
  l_motnja_id    VARCHAR2(36);
  l_existing     NUMBER;
  l_lat          NUMBER;
  l_lon          NUMBER;
  l_loc_acc      VARCHAR2(20);
  l_observed_at  TIMESTAMP;
  l_observed_str VARCHAR2(40);
  l_description  CLOB;
  l_action       VARCHAR2(50);
  l_proposed     VARCHAR2(500);
  l_types_n      PLS_INTEGER;
  l_obs_n        PLS_INTEGER;
  l_skup         VARCHAR2(2);
  l_tip          VARCHAR2(4);
  l_obs_name     VARCHAR2(200);
  l_status       PLS_INTEGER := 201;
  l_out          CLOB;

  PROCEDURE dlog(
    p_step IN VARCHAR2,
    p_email IN VARCHAR2 DEFAULT NULL,
    p_org IN NUMBER DEFAULT NULL,
    p_id IN VARCHAR2 DEFAULT NULL,
    p_existing IN NUMBER DEFAULT NULL,
    p_err IN VARCHAR2 DEFAULT NULL
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO tb_motnje_debug (
      runtime_user, step_reached, auth_email, auth_org_id,
      body_len, parsed_id, existing_cnt, err_msg, raw_body
    ) VALUES (
      USER, p_step, p_email, p_org,
      DBMS_LOB.getlength(l_body), p_id, p_existing, p_err,
      CASE WHEN p_step = 'entry' THEN l_body ELSE NULL END
    );
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN ROLLBACK;
  END dlog;
BEGIN
  dlog('entry');

  BEGIN
    l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION
    WHEN pkg_tb_auth.e_unauthorized THEN
      dlog('auth_failed');
      :status_code  := 401;
      :content_type := 'application/json';
      HTP.prn('{"error":"unauthorized"}');
      RETURN;
  END;
  dlog('auth_ok', l_ctx.email, l_ctx.org_id);

  IF l_body IS NULL OR DBMS_LOB.getlength(l_body) = 0 THEN
    dlog('empty_body', l_ctx.email, l_ctx.org_id);
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"empty_body"}');
    RETURN;
  END IF;

  BEGIN
    APEX_JSON.parse(l_body);
  EXCEPTION
    WHEN OTHERS THEN
      dlog('bad_json', l_ctx.email, l_ctx.org_id, NULL, NULL, SQLERRM);
      :status_code  := 400;
      :content_type := 'application/json';
      HTP.prn('{"error":"bad_json"}');
      RETURN;
  END;

  l_motnja_id    := APEX_JSON.get_varchar2(p_path => 'id');
  l_lat          := APEX_JSON.get_number  (p_path => 'latitude');
  l_lon          := APEX_JSON.get_number  (p_path => 'longitude');
  l_loc_acc      := APEX_JSON.get_varchar2(p_path => 'locationAccuracy');
  l_observed_str := APEX_JSON.get_varchar2(p_path => 'observedAt');
  l_description  := APEX_JSON.get_clob    (p_path => 'description');
  l_action       := APEX_JSON.get_varchar2(p_path => 'actionTaken');
  l_proposed     := APEX_JSON.get_varchar2(p_path => 'proposedType');

  dlog('parsed', l_ctx.email, l_ctx.org_id, l_motnja_id);

  IF l_motnja_id IS NULL OR l_lat IS NULL OR l_lon IS NULL
     OR l_loc_acc IS NULL OR l_observed_str IS NULL OR l_action IS NULL
  THEN
    dlog('missing_required_field', l_ctx.email, l_ctx.org_id, l_motnja_id);
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"missing_required_field"}');
    RETURN;
  END IF;

  BEGIN
    l_observed_at := TO_TIMESTAMP_TZ(REPLACE(l_observed_str, 'Z', '+00:00'),
                                     'YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM');
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        l_observed_at := TO_TIMESTAMP(SUBSTR(l_observed_str, 1, 19),
                                      'YYYY-MM-DD"T"HH24:MI:SS');
      EXCEPTION
        WHEN OTHERS THEN
          dlog('bad_observedAt', l_ctx.email, l_ctx.org_id, l_motnja_id, NULL, l_observed_str);
          :status_code  := 400;
          :content_type := 'application/json';
          HTP.prn('{"error":"bad_observedAt"}');
          RETURN;
      END;
  END;

  SELECT COUNT(*) INTO l_existing FROM tb_motnje WHERE motnja_id = l_motnja_id;
  dlog('existing_check', l_ctx.email, l_ctx.org_id, l_motnja_id, l_existing);

  IF l_existing > 0 THEN
    l_status := 200;
    GOTO respond;
  END IF;

  BEGIN
    INSERT INTO tb_motnje (
      motnja_id, org_id, geo_sirina, geo_dolzina, natancnost_lok,
      cas_opazovanja, opis, ukrepanje, predlog_tipa, ustvarjen_od
    ) VALUES (
      l_motnja_id, l_ctx.org_id, l_lat, l_lon, l_loc_acc,
      l_observed_at, l_description, l_action, l_proposed, l_ctx.email
    );
    dlog('inserted_main', l_ctx.email, l_ctx.org_id, l_motnja_id);
  EXCEPTION
    WHEN OTHERS THEN
      dlog('insert_main_err', l_ctx.email, l_ctx.org_id, l_motnja_id, NULL, SQLERRM);
      RAISE;
  END;

  l_types_n := APEX_JSON.get_count(p_path => 'types');
  IF l_types_n IS NOT NULL THEN
    FOR i IN 1 .. l_types_n LOOP
      l_skup := APEX_JSON.get_varchar2(p_path => 'types[%d].groupCode', p0 => i);
      l_tip  := APEX_JSON.get_varchar2(p_path => 'types[%d].typeCode',  p0 => i);
      IF l_skup IS NOT NULL AND l_tip IS NOT NULL THEN
        BEGIN
          INSERT INTO tb_motnje_tipi_dogodka (motnja_id, skupina_koda, tip_koda)
          VALUES (l_motnja_id, l_skup, l_tip);
        EXCEPTION
          WHEN DUP_VAL_ON_INDEX THEN NULL;
        END;
      END IF;
    END LOOP;
  END IF;

  l_obs_n := APEX_JSON.get_count(p_path => 'observers');
  IF l_obs_n IS NOT NULL THEN
    FOR i IN 1 .. l_obs_n LOOP
      l_obs_name := APEX_JSON.get_varchar2(p_path => 'observers[%d]', p0 => i);
      IF l_obs_name IS NOT NULL AND LENGTH(TRIM(l_obs_name)) > 0 THEN
        BEGIN
          INSERT INTO tb_motnje_opazovalci (motnja_id, ime_opazovalca)
          VALUES (l_motnja_id, SUBSTR(TRIM(l_obs_name), 1, 200));
        EXCEPTION
          WHEN DUP_VAL_ON_INDEX THEN NULL;
        END;
      END IF;
    END LOOP;
  END IF;

  COMMIT;
  dlog('committed', l_ctx.email, l_ctx.org_id, l_motnja_id);

  <<respond>>
  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('id', l_motnja_id);
  APEX_JSON.write('status', CASE WHEN l_status = 201 THEN 'created' ELSE 'exists' END);
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := l_status;
  :content_type := 'application/json';
  HTP.prn(l_out);
  dlog('responded_' || l_status, l_ctx.email, l_ctx.org_id, l_motnja_id);
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '/',
    p_method => 'POST', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '/',
    p_method => 'POST', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- PUT disturbances/:id    (unchanged from disturbance_endpoints.sql)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_body         CLOB := :body_text;
  l_motnja_id    VARCHAR2(36) := :id;
  l_existing_org NUMBER;
  l_lat          NUMBER;
  l_lon          NUMBER;
  l_loc_acc      VARCHAR2(20);
  l_observed_str VARCHAR2(40);
  l_observed_at  TIMESTAMP;
  l_description  CLOB;
  l_action       VARCHAR2(50);
  l_proposed     VARCHAR2(500);
  l_types_n      PLS_INTEGER;
  l_obs_n        PLS_INTEGER;
  l_skup         VARCHAR2(2);
  l_tip          VARCHAR2(4);
  l_obs_name     VARCHAR2(200);
  l_out          CLOB;
BEGIN
  BEGIN l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION WHEN pkg_tb_auth.e_unauthorized THEN
    :status_code := 401; :content_type := 'application/json';
    HTP.prn('{"error":"unauthorized"}'); RETURN;
  END;

  IF l_body IS NULL OR DBMS_LOB.getlength(l_body) = 0 THEN
    :status_code := 400; :content_type := 'application/json';
    HTP.prn('{"error":"empty_body"}'); RETURN;
  END IF;

  BEGIN APEX_JSON.parse(l_body);
  EXCEPTION WHEN OTHERS THEN
    :status_code := 400; :content_type := 'application/json';
    HTP.prn('{"error":"bad_json"}'); RETURN;
  END;

  l_lat          := APEX_JSON.get_number  (p_path => 'latitude');
  l_lon          := APEX_JSON.get_number  (p_path => 'longitude');
  l_loc_acc      := APEX_JSON.get_varchar2(p_path => 'locationAccuracy');
  l_observed_str := APEX_JSON.get_varchar2(p_path => 'observedAt');
  l_description  := APEX_JSON.get_clob    (p_path => 'description');
  l_action       := APEX_JSON.get_varchar2(p_path => 'actionTaken');
  l_proposed     := APEX_JSON.get_varchar2(p_path => 'proposedType');

  IF l_lat IS NULL OR l_lon IS NULL OR l_loc_acc IS NULL
     OR l_observed_str IS NULL OR l_action IS NULL THEN
    :status_code := 400; :content_type := 'application/json';
    HTP.prn('{"error":"missing_required_field"}'); RETURN;
  END IF;

  BEGIN
    l_observed_at := TO_TIMESTAMP_TZ(REPLACE(l_observed_str, 'Z', '+00:00'),
                                     'YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM');
  EXCEPTION WHEN OTHERS THEN
    BEGIN l_observed_at := TO_TIMESTAMP(SUBSTR(l_observed_str, 1, 19),
                                        'YYYY-MM-DD"T"HH24:MI:SS');
    EXCEPTION WHEN OTHERS THEN
      :status_code := 400; :content_type := 'application/json';
      HTP.prn('{"error":"bad_observedAt"}'); RETURN;
    END;
  END;

  BEGIN
    SELECT org_id INTO l_existing_org FROM tb_motnje
     WHERE motnja_id = l_motnja_id FOR UPDATE;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    :status_code := 404; :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}'); RETURN;
  END;
  IF l_existing_org <> l_ctx.org_id THEN
    :status_code := 404; :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}'); RETURN;
  END IF;

  UPDATE tb_motnje
     SET geo_sirina = l_lat, geo_dolzina = l_lon, natancnost_lok = l_loc_acc,
         cas_opazovanja = l_observed_at, opis = l_description,
         ukrepanje = l_action, predlog_tipa = l_proposed,
         spremenjen_od = l_ctx.email, spremenjen = SYSTIMESTAMP
   WHERE motnja_id = l_motnja_id;

  DELETE FROM tb_motnje_tipi_dogodka WHERE motnja_id = l_motnja_id;
  DELETE FROM tb_motnje_opazovalci   WHERE motnja_id = l_motnja_id;

  l_types_n := APEX_JSON.get_count(p_path => 'types');
  IF l_types_n IS NOT NULL THEN
    FOR i IN 1 .. l_types_n LOOP
      l_skup := APEX_JSON.get_varchar2(p_path => 'types[%d].groupCode', p0 => i);
      l_tip  := APEX_JSON.get_varchar2(p_path => 'types[%d].typeCode',  p0 => i);
      IF l_skup IS NOT NULL AND l_tip IS NOT NULL THEN
        BEGIN INSERT INTO tb_motnje_tipi_dogodka (motnja_id, skupina_koda, tip_koda)
              VALUES (l_motnja_id, l_skup, l_tip);
        EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
      END IF;
    END LOOP;
  END IF;

  l_obs_n := APEX_JSON.get_count(p_path => 'observers');
  IF l_obs_n IS NOT NULL THEN
    FOR i IN 1 .. l_obs_n LOOP
      l_obs_name := APEX_JSON.get_varchar2(p_path => 'observers[%d]', p0 => i);
      IF l_obs_name IS NOT NULL AND LENGTH(TRIM(l_obs_name)) > 0 THEN
        BEGIN INSERT INTO tb_motnje_opazovalci (motnja_id, ime_opazovalca)
              VALUES (l_motnja_id, SUBSTR(TRIM(l_obs_name), 1, 200));
        EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
      END IF;
    END LOOP;
  END IF;

  COMMIT;

  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('id', l_motnja_id);
  APEX_JSON.write('status', 'updated');
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code := 200; :content_type := 'application/json';
  HTP.prn(l_out);
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'PUT', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'PUT', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- DELETE disturbances/:id   (unchanged from disturbance_endpoints.sql)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_motnja_id    VARCHAR2(36) := :id;
  l_existing_org NUMBER;
BEGIN
  BEGIN l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION WHEN pkg_tb_auth.e_unauthorized THEN
    :status_code := 401; :content_type := 'application/json';
    HTP.prn('{"error":"unauthorized"}'); RETURN;
  END;

  BEGIN
    SELECT org_id INTO l_existing_org FROM tb_motnje
     WHERE motnja_id = l_motnja_id FOR UPDATE;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    :status_code := 404; :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}'); RETURN;
  END;
  IF l_existing_org <> l_ctx.org_id THEN
    :status_code := 404; :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}'); RETURN;
  END IF;

  DELETE FROM tb_motnje WHERE motnja_id = l_motnja_id;
  COMMIT;

  :status_code := 204; :content_type := 'application/json';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  COMMIT;
END;
/
