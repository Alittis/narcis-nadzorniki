--------------------------------------------------------------------------------
-- ORDS module: narcis_walks
--   GET    /ords/narcis/walks/                - list (caller's org)
--   POST   /ords/narcis/walks/                - create (with inline points)
--   PUT    /ords/narcis/walks/:id             - update name + notes only
--   DELETE /ords/narcis/walks/:id             - delete (points cascade,
--                                               linked disturbances unlink)
--   GET    /ords/narcis/walks/:id/points      - fetch the track points
--
-- Auth: X-Narcis-Auth: Basic <base64(email:password)> on every call (same
--   wire format as /app-auth/login and the disturbance endpoints; uses
--   pkg_tb_auth.authenticate). Single failure mode -> 401.
--
-- Idempotency:
--   POST is idempotent on obhod_id. The phone generates the UUID at the
--   moment the user starts the walk, so a retry after a lost response
--   returns 200 with the existing row instead of 201. Track points are
--   only inserted on the first successful POST - duplicates are a no-op
--   regardless of any difference in the points array.
--
-- Org scoping:
--   ORG_ID is stamped server-side from pkg_tb_auth.authenticate. Clients
--   never send it. PUT/DELETE/points-GET silently 404 when the target
--   walk's org_id doesn't match the caller's - same non-leaking pattern
--   as the disturbance endpoints.
--
-- Edits:
--   PUT only updates NAZIV and OPIS. Times and points are write-once
--   (matches the "edits offline don't queue" model in app_state.dart).
--
-- POST body shape:
--   { "id": "<uuid>",
--     "startedAt": "<ISO-8601 UTC>",
--     "endedAt":   "<ISO-8601 UTC>",
--     "name":      "..." | null,
--     "notes":     "..." | null,
--     "points": [
--       { "seq": 0, "lat": <num>, "lon": <num>,
--         "t": "<ISO-8601 UTC>", "accuracy": <num>|null },
--       ...
--     ]
--   }
--
-- PUT body shape:
--   { "name": "..." | null, "notes": "..." | null }
--
-- GET / response shape:
--   { "walks": [
--       { "id": "...",
--         "startedAt": "...", "endedAt": "...",
--         "name": "...", "notes": "...",
--         "createdAt": "...", "createdBy": "<email>",
--         "pointCount": <int>, "disturbanceCount": <int>
--       },
--       ...
--     ] }
--
-- GET :id/points response shape:
--   { "obhodId": "...",
--     "points": [
--       { "seq": 0, "lat": ..., "lon": ..., "t": "...", "accuracy": ... },
--       ...
--     ] }
--
-- Idempotent: existing module is dropped first, so re-running this script
-- is safe.
--------------------------------------------------------------------------------

BEGIN
  ORDS.DELETE_MODULE(p_module_name => 'narcis_walks');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'narcis_walks',
    p_base_path      => 'walks/',
    p_items_per_page => 0
  );

  ----------------------------------------------------------------------------
  -- GET walks/   (list - caller's org)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_walks',
    p_pattern     => '/'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_walks',
    p_pattern     => '/',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx pkg_tb_auth.t_auth_ctx;
  l_out CLOB;
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

  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.open_array('walks');
  FOR rec IN (
    SELECT o.obhod_id, o.zacetek, o.konec, o.naziv, o.opis,
           o.ustvarjen, o.ustvarjen_od,
           (SELECT COUNT(*) FROM tb_obhodi_tocke t WHERE t.obhod_id = o.obhod_id) AS point_count,
           (SELECT COUNT(*) FROM tb_motnje      m WHERE m.obhod_id = o.obhod_id) AS dist_count
      FROM tb_obhodi o
     WHERE o.org_id = l_ctx.org_id
     ORDER BY o.zacetek DESC, o.ustvarjen DESC
  ) LOOP
    APEX_JSON.open_object;
    APEX_JSON.write('id',        rec.obhod_id);
    APEX_JSON.write('startedAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.zacetek AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('endedAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.konec AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('name',  rec.naziv);
    APEX_JSON.write('notes', rec.opis);
    APEX_JSON.write('createdAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.ustvarjen AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('createdBy',        rec.ustvarjen_od);
    APEX_JSON.write('pointCount',       rec.point_count);
    APEX_JSON.write('disturbanceCount', rec.dist_count);
    APEX_JSON.close_object;
  END LOOP;
  APEX_JSON.close_array;
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := 200;
  :content_type := 'application/json';
  -- Chunk-emit so HTP.prn never gets a CLOB it has to implicitly convert
  -- to VARCHAR2 (ORA-06502 above ~32 KB). Triggers on orgs with many walks.
  DECLARE
    l_pos INTEGER := 1;
    l_amt INTEGER;
    l_len INTEGER := DBMS_LOB.getlength(l_out);
  BEGIN
    WHILE l_pos <= l_len LOOP
      l_amt := LEAST(8000, l_len - l_pos + 1);
      HTP.prn(DBMS_LOB.substr(l_out, l_amt, l_pos));
      l_pos := l_pos + l_amt;
    END LOOP;
  END;
EXCEPTION
  WHEN OTHERS THEN
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => '/',
    p_method => 'GET', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => '/',
    p_method => 'GET', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST walks/
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_walks',
    p_pattern     => '/',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_body         CLOB := :body_text;
  l_obhod_id     VARCHAR2(36);
  l_existing     NUMBER;
  l_zac_str      VARCHAR2(40);
  l_kon_str      VARCHAR2(40);
  l_zacetek      TIMESTAMP;
  l_konec        TIMESTAMP;
  l_naziv        VARCHAR2(200);
  l_opis         CLOB;
  l_pts_n        PLS_INTEGER;
  l_status       PLS_INTEGER := 201;
  l_out          CLOB;

  TYPE t_pts_tab IS TABLE OF tb_obhodi_tocke%ROWTYPE INDEX BY PLS_INTEGER;
  l_pts t_pts_tab;

  -- ISO-8601 ("...Z" or "...+HH:MM") -> TIMESTAMP. Falls back to a no-FF
  -- second-precision parse so a phone that drops fractional seconds still
  -- works. Raises whatever the inner TO_TIMESTAMP* raises if both fail.
  FUNCTION parse_iso(p_s VARCHAR2) RETURN TIMESTAMP IS
    l_t TIMESTAMP;
  BEGIN
    l_t := TO_TIMESTAMP_TZ(REPLACE(p_s, 'Z', '+00:00'),
                           'YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM');
    RETURN l_t;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN TO_TIMESTAMP(SUBSTR(p_s, 1, 19),
                          'YYYY-MM-DD"T"HH24:MI:SS');
  END parse_iso;
BEGIN
  -- 1. Authenticate
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

  l_obhod_id := APEX_JSON.get_varchar2(p_path => 'id');
  l_zac_str  := APEX_JSON.get_varchar2(p_path => 'startedAt');
  l_kon_str  := APEX_JSON.get_varchar2(p_path => 'endedAt');
  l_naziv    := APEX_JSON.get_varchar2(p_path => 'name');
  l_opis     := APEX_JSON.get_clob    (p_path => 'notes');

  IF l_obhod_id IS NULL OR l_zac_str IS NULL OR l_kon_str IS NULL THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"missing_required_field"}');
    RETURN;
  END IF;

  BEGIN
    l_zacetek := parse_iso(l_zac_str);
    l_konec   := parse_iso(l_kon_str);
  EXCEPTION
    WHEN OTHERS THEN
      :status_code  := 400;
      :content_type := 'application/json';
      HTP.prn('{"error":"bad_timestamp"}');
      RETURN;
  END;

  IF l_konec < l_zacetek THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"end_before_start"}');
    RETURN;
  END IF;

  -- 3. Idempotency: if obhod_id already exists, return 200. Don't
  --    re-insert points - the first POST is the source of truth.
  SELECT COUNT(*) INTO l_existing FROM tb_obhodi WHERE obhod_id = l_obhod_id;
  IF l_existing > 0 THEN
    l_status := 200;
    GOTO respond;
  END IF;

  -- 4. Insert main row
  INSERT INTO tb_obhodi (
    obhod_id, org_id, zacetek, konec, naziv, opis, ustvarjen_od
  ) VALUES (
    l_obhod_id, l_ctx.org_id, l_zacetek, l_konec, l_naziv, l_opis, l_ctx.email
  );

  -- 5. Build the points array and bulk-insert. A 2-hour walk at the 5 m
  --    distance filter is roughly 1.5-2k points; FORALL is materially
  --    faster than per-row INSERTs in that range.
  l_pts_n := APEX_JSON.get_count(p_path => 'points');
  IF l_pts_n IS NOT NULL AND l_pts_n > 0 THEN
    FOR i IN 1 .. l_pts_n LOOP
      l_pts(i).obhod_id    := l_obhod_id;
      l_pts(i).seq         := APEX_JSON.get_number  (p_path => 'points[%d].seq',      p0 => i);
      l_pts(i).geo_sirina  := APEX_JSON.get_number  (p_path => 'points[%d].lat',      p0 => i);
      l_pts(i).geo_dolzina := APEX_JSON.get_number  (p_path => 'points[%d].lon',      p0 => i);
      l_pts(i).natancnost  := APEX_JSON.get_number  (p_path => 'points[%d].accuracy', p0 => i);
      l_pts(i).cas         := parse_iso(APEX_JSON.get_varchar2(p_path => 'points[%d].t', p0 => i));
    END LOOP;

    FORALL i IN 1 .. l_pts.COUNT
      INSERT INTO tb_obhodi_tocke VALUES l_pts(i);
  END IF;

  COMMIT;

  <<respond>>
  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('id', l_obhod_id);
  APEX_JSON.write('status', CASE WHEN l_status = 201 THEN 'created' ELSE 'exists' END);
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := l_status;
  :content_type := 'application/json';
  HTP.prn(l_out);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => '/',
    p_method => 'POST', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => '/',
    p_method => 'POST', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- PUT walks/:id   (name + notes only; times and points are write-once)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_walks',
    p_pattern     => ':id'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_walks',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_body         CLOB := :body_text;
  l_obhod_id     VARCHAR2(36) := :id;
  l_existing_org NUMBER;
  l_naziv        VARCHAR2(200);
  l_opis         CLOB;
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

  l_naziv := APEX_JSON.get_varchar2(p_path => 'name');
  l_opis  := APEX_JSON.get_clob    (p_path => 'notes');

  BEGIN
    SELECT org_id INTO l_existing_org
      FROM tb_obhodi
     WHERE obhod_id = l_obhod_id
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

  UPDATE tb_obhodi
     SET naziv         = l_naziv,
         opis          = l_opis,
         spremenjen_od = l_ctx.email,
         spremenjen    = SYSTIMESTAMP
   WHERE obhod_id = l_obhod_id;

  COMMIT;

  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('id', l_obhod_id);
  APEX_JSON.write('status', 'updated');
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := 200;
  :content_type := 'application/json';
  HTP.prn(l_out);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id',
    p_method => 'PUT', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id',
    p_method => 'PUT', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- DELETE walks/:id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_walks',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_obhod_id     VARCHAR2(36) := :id;
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
      FROM tb_obhodi
     WHERE obhod_id = l_obhod_id
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

  -- Points cascade. tb_motnje.obhod_id is set NULL by the FK rule.
  DELETE FROM tb_obhodi WHERE obhod_id = l_obhod_id;
  COMMIT;

  :status_code  := 204;
  :content_type := 'application/json';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- GET walks/:id/points
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_walks',
    p_pattern     => ':id/points'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_walks',
    p_pattern     => ':id/points',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_obhod_id     VARCHAR2(36) := :id;
  l_existing_org NUMBER;
  l_out          CLOB;
  -- Last seq we attempted to write to JSON; surfaces in the WHEN OTHERS
  -- response so a row-specific data fault names the offending point.
  l_diag_seq     NUMBER;
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
      FROM tb_obhodi
     WHERE obhod_id = l_obhod_id;
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

  APEX_JSON.free_output;
  APEX_JSON.initialize_clob_output;
  APEX_JSON.open_object;
  APEX_JSON.write('obhodId', l_obhod_id);
  APEX_JSON.open_array('points');
  FOR p IN (
    SELECT seq, geo_sirina, geo_dolzina, cas, natancnost
      FROM tb_obhodi_tocke
     WHERE obhod_id = l_obhod_id
     ORDER BY seq
  ) LOOP
    l_diag_seq := p.seq;
    APEX_JSON.open_object;
    APEX_JSON.write('seq',      p.seq);
    APEX_JSON.write('lat',      p.geo_sirina);
    APEX_JSON.write('lon',      p.geo_dolzina);
    APEX_JSON.write('t',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(p.cas AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('accuracy', p.natancnost);
    APEX_JSON.close_object;
  END LOOP;
  APEX_JSON.close_array;
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := 200;
  :content_type := 'application/json';
  -- Chunk-emit so HTP.prn never gets a CLOB it has to implicitly convert
  -- to VARCHAR2 (ORA-06502 once the body exceeds ~32 KB; a long walk's
  -- points payload trips this around 340+ rows).
  DECLARE
    l_pos INTEGER := 1;
    l_amt INTEGER;
    l_len INTEGER := DBMS_LOB.getlength(l_out);
  BEGIN
    WHILE l_pos <= l_len LOOP
      l_amt := LEAST(8000, l_len - l_pos + 1);
      HTP.prn(DBMS_LOB.substr(l_out, l_amt, l_pos));
      l_pos := l_pos + l_amt;
    END LOOP;
  END;
EXCEPTION
  WHEN OTHERS THEN
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error"'
            || ',"sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"'
            || ',"diag_seq":' || NVL(TO_CHAR(l_diag_seq), 'null')
            || ',"backtrace":"'
            || REPLACE(REPLACE(REPLACE(
                 SUBSTR(dbms_utility.format_error_backtrace, 1, 800),
                 '\', '\\'), '"', '\"'), CHR(10), '\n')
            || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id/points',
    p_method => 'GET', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_walks', p_pattern => ':id/points',
    p_method => 'GET', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  COMMIT;
END;
/
