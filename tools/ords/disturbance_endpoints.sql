--------------------------------------------------------------------------------
-- ORDS module: narcis_disturbances
--   POST   /ords/narcis/disturbances/        - create
--   PUT    /ords/narcis/disturbances/:id     - update
--   DELETE /ords/narcis/disturbances/:id     - delete
--
-- Auth: X-Narcis-Auth: Basic <base64(email:password)> on every call.
--   Same wire format as /app-auth/login. Re-validating the password on each
--   call is intentional for now (see ARCHITECTURE.md §8 - bearer tokens are
--   a follow-up); pkg_tb_auth.authenticate raises on any failure -> 401.
--
-- Idempotency:
--   POST is idempotent on motnja_id. The phone generates the UUID at create
--   time; if the same UUID arrives twice (e.g. retry after a lost response),
--   the second call is a no-op and returns 200 with the existing row's
--   timestamp instead of 201.
--
-- Org scoping:
--   ORG_ID is stamped server-side from pkg_tb_auth's auth context. Clients
--   never send it. PUT/DELETE silently 404 if the target row's org_id
--   doesn't match the caller's org - "not yours" is indistinguishable from
--   "not found" to avoid leaking the existence of cross-tenant rows.
--
-- Request body shape (matches Disturbance.toJson on the Flutter side):
--   { "id": "<uuid>",
--     "latitude": <num>, "longitude": <num>,
--     "locationAccuracy": "natancna" | "priblizna",
--     "observedAt": "<ISO-8601 UTC>",
--     "types": [{ "groupCode": "1", "typeCode": "a", ... }, ...],
--     "description": "...",
--     "observers": ["...", ...],
--     "actionTaken": "...",
--     "proposedType": "..." | null
--   }
--   (createdAt, groupName/typeName, photoPaths, pendingSync are ignored.)
--
-- Idempotent: existing module is dropped first, so re-running this script
-- is safe.
--------------------------------------------------------------------------------

-- Drop any prior definition so the script is re-runnable.
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
  -- POST disturbances/
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
BEGIN
  -- 1. Authenticate (raises e_unauthorized -> 401)
  BEGIN
    l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION
    WHEN pkg_tb_auth.e_unauthorized THEN
      :status_code  := 401;
      :content_type := 'application/json';
      HTP.prn('{"error":"unauthorized"}');
      RETURN;
  END;

  -- 2. Parse body
  IF l_body IS NULL OR DBMS_LOB.getlength(l_body) = 0 THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"empty_body"}');
    RETURN;
  END IF;

  BEGIN
    APEX_JSON.parse(l_body);
  EXCEPTION
    WHEN OTHERS THEN
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

  IF l_motnja_id IS NULL
     OR l_lat IS NULL OR l_lon IS NULL
     OR l_loc_acc IS NULL OR l_observed_str IS NULL
     OR l_action IS NULL
  THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"missing_required_field"}');
    RETURN;
  END IF;

  BEGIN
    -- ISO-8601 with 'Z' suffix for UTC. Strip the Z and parse as UTC.
    l_observed_at := TO_TIMESTAMP_TZ(REPLACE(l_observed_str, 'Z', '+00:00'),
                                     'YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM');
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        l_observed_at := TO_TIMESTAMP(SUBSTR(l_observed_str, 1, 19),
                                      'YYYY-MM-DD"T"HH24:MI:SS');
      EXCEPTION
        WHEN OTHERS THEN
          :status_code  := 400;
          :content_type := 'application/json';
          HTP.prn('{"error":"bad_observedAt"}');
          RETURN;
      END;
  END;

  -- 3. Idempotency: if motnja_id already exists, return 200 instead of 201.
  --    Cross-org collisions are vanishingly unlikely with UUIDs but if one
  --    happens we still 200 - we don't leak whose row it is.
  SELECT COUNT(*) INTO l_existing FROM tb_motnje WHERE motnja_id = l_motnja_id;
  IF l_existing > 0 THEN
    l_status := 200;
    GOTO respond;
  END IF;

  -- 4. Insert main record
  INSERT INTO tb_motnje (
    motnja_id, org_id, geo_sirina, geo_dolzina, natancnost_lok,
    cas_opazovanja, opis, ukrepanje, predlog_tipa, ustvarjen_od
  ) VALUES (
    l_motnja_id, l_ctx.org_id, l_lat, l_lon, l_loc_acc,
    l_observed_at, l_description, l_action, l_proposed, l_ctx.email
  );

  -- 5. Insert type junction rows
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
          WHEN DUP_VAL_ON_INDEX THEN NULL;  -- duplicate type within same record: ignore
        END;
      END IF;
    END LOOP;
  END IF;

  -- 6. Insert observer junction rows
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
  -- PUT disturbances/:id
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
  BEGIN
    l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION
    WHEN pkg_tb_auth.e_unauthorized THEN
      :status_code  := 401;
      :content_type := 'application/json';
      HTP.prn('{"error":"unauthorized"}');
      RETURN;
  END;

  IF l_body IS NULL OR DBMS_LOB.getlength(l_body) = 0 THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"empty_body"}');
    RETURN;
  END IF;

  BEGIN
    APEX_JSON.parse(l_body);
  EXCEPTION
    WHEN OTHERS THEN
      :status_code  := 400;
      :content_type := 'application/json';
      HTP.prn('{"error":"bad_json"}');
      RETURN;
  END;

  l_lat          := APEX_JSON.get_number  (p_path => 'latitude');
  l_lon          := APEX_JSON.get_number  (p_path => 'longitude');
  l_loc_acc      := APEX_JSON.get_varchar2(p_path => 'locationAccuracy');
  l_observed_str := APEX_JSON.get_varchar2(p_path => 'observedAt');
  l_description  := APEX_JSON.get_clob    (p_path => 'description');
  l_action       := APEX_JSON.get_varchar2(p_path => 'actionTaken');
  l_proposed     := APEX_JSON.get_varchar2(p_path => 'proposedType');

  IF l_lat IS NULL OR l_lon IS NULL OR l_loc_acc IS NULL
     OR l_observed_str IS NULL OR l_action IS NULL
  THEN
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
          :status_code  := 400;
          :content_type := 'application/json';
          HTP.prn('{"error":"bad_observedAt"}');
          RETURN;
      END;
  END;

  -- Find target row scoped to caller's org. 404 if missing OR cross-tenant.
  BEGIN
    SELECT org_id INTO l_existing_org
      FROM tb_motnje
     WHERE motnja_id = l_motnja_id
       FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      :status_code  := 404;
      :content_type := 'application/json';
      HTP.prn('{"error":"not_found"}');
      RETURN;
  END;
  IF l_existing_org <> l_ctx.org_id THEN
    :status_code  := 404;
    :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}');
    RETURN;
  END IF;

  UPDATE tb_motnje
     SET geo_sirina     = l_lat,
         geo_dolzina    = l_lon,
         natancnost_lok = l_loc_acc,
         cas_opazovanja = l_observed_at,
         opis           = l_description,
         ukrepanje      = l_action,
         predlog_tipa   = l_proposed,
         spremenjen_od  = l_ctx.email,
         spremenjen     = SYSTIMESTAMP
   WHERE motnja_id = l_motnja_id;

  -- Replace junctions wholesale: simpler than diffing.
  DELETE FROM tb_motnje_tipi_dogodka WHERE motnja_id = l_motnja_id;
  DELETE FROM tb_motnje_opazovalci   WHERE motnja_id = l_motnja_id;

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

  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('id', l_motnja_id);
  APEX_JSON.write('status', 'updated');
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := 200;
  :content_type := 'application/json';
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
  -- DELETE disturbances/:id
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
  BEGIN
    l_ctx := pkg_tb_auth.authenticate;
  EXCEPTION
    WHEN pkg_tb_auth.e_unauthorized THEN
      :status_code  := 401;
      :content_type := 'application/json';
      HTP.prn('{"error":"unauthorized"}');
      RETURN;
  END;

  BEGIN
    SELECT org_id INTO l_existing_org
      FROM tb_motnje
     WHERE motnja_id = l_motnja_id
       FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      :status_code  := 404;
      :content_type := 'application/json';
      HTP.prn('{"error":"not_found"}');
      RETURN;
  END;
  IF l_existing_org <> l_ctx.org_id THEN
    :status_code  := 404;
    :content_type := 'application/json';
    HTP.prn('{"error":"not_found"}');
    RETURN;
  END IF;

  -- Junctions cascade.
  DELETE FROM tb_motnje WHERE motnja_id = l_motnja_id;
  COMMIT;

  :status_code  := 204;
  :content_type := 'application/json';
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
