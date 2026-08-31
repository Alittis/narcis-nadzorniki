--------------------------------------------------------------------------------
-- ORDS module: narcis_disturbances
--   GET    /ords/narcis/disturbances/                       - list (caller's org)
--   POST   /ords/narcis/disturbances/                       - create
--   PUT    /ords/narcis/disturbances/:id                    - update
--   DELETE /ords/narcis/disturbances/:id                    - delete
--   POST   /ords/narcis/disturbances/:id/photos/:photoId    - upload photo BLOB
--   GET    /ords/narcis/disturbances/:id/photos/:photoId    - download photo BLOB
--   DELETE /ords/narcis/disturbances/:id/photos/:photoId    - delete photo
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
--     "legalBasis": "..." | null,
--     "caseStatus": "Odprto" | "V obravnavi" | "Zaključeno" | "Predano drugi službi",
--     "proposedType": "..." | null,
--     "obhodId": "<uuid>" | null
--   }
--   (createdAt, groupName/typeName, photos, pendingSync are ignored.)
--   `caseStatus` is required by the DB CHECK; if missing the handler
--   substitutes 'Odprto' on POST and the existing row's value on PUT so
--   older clients keep working. `legalBasis` is free-text and may be NULL.
--   `obhodId` links the record to a walk-around (TB_OBHODI). May be NULL
--   for records created outside a walk. The walk row must already exist
--   (FK is validated server-side) - the client should POST the walk first.
--
-- GET /  response shape (caller's org only; photos returned as IDs+MIME, BLOBs
-- are fetched lazily via the photo endpoint):
--   { "records": [
--       { "id": "...",
--         "latitude": <num>, "longitude": <num>,
--         "locationAccuracy": "...",
--         "observedAt": "<ISO-8601 UTC>",
--         "createdAt":  "<ISO-8601 UTC>",
--         "createdBy":  "<email>",
--         "types":      [{ "groupCode": "...", "typeCode": "..." }, ...],
--         "description": "...",
--         "observers":  ["...", ...],
--         "actionTaken": "...",
--         "legalBasis": "..." | null,
--         "caseStatus": "Odprto" | "V obravnavi" | "Zaključeno" | "Predano drugi službi",
--         "proposedType": "..." | null,
--         "obhodId":    "..." | null,
--         "photos":     [{ "id": "...", "mimeType": "image/jpeg" }, ...]
--       },
--       ...
--     ] }
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
  -- GET disturbances/   (list - caller's org only)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_disturbances',
    p_pattern     => '/'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
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
  APEX_JSON.open_array('records');
  FOR rec IN (
    SELECT motnja_id, geo_sirina, geo_dolzina, natancnost_lok,
           cas_opazovanja, opis, ukrepanje, zakonska_podlaga, status_obravnave,
           predlog_tipa, ustvarjen, ustvarjen_od, obhod_id,
           obravnaval, obravnavano
      FROM tb_motnje
     WHERE org_id = l_ctx.org_id
     ORDER BY cas_opazovanja DESC, ustvarjen DESC
  ) LOOP
    APEX_JSON.open_object;
    APEX_JSON.write('id',               rec.motnja_id);
    APEX_JSON.write('latitude',         rec.geo_sirina);
    APEX_JSON.write('longitude',        rec.geo_dolzina);
    APEX_JSON.write('locationAccuracy', rec.natancnost_lok);
    APEX_JSON.write('observedAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.cas_opazovanja AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('createdAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.ustvarjen AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
    APEX_JSON.write('createdBy',    rec.ustvarjen_od);
    APEX_JSON.write('description',  rec.opis);
    APEX_JSON.write('actionTaken',  rec.ukrepanje);
    APEX_JSON.write('legalBasis',   rec.zakonska_podlaga);
    APEX_JSON.write('caseStatus',   rec.status_obravnave);
    APEX_JSON.write('proposedType', rec.predlog_tipa);
    APEX_JSON.write('obhodId',      rec.obhod_id);

    -- Case review (TB-26 half 1): read-only here. The web backoffice is the only
    -- writer of these columns (narcis-vibed NV-220); see the TB_MOTNJE header note
    -- in disturbance_schema.sql. OPOMBA_URADNA is deliberately NOT selected --
    -- whether the warden sees the reviewer's note is an open product decision
    -- (TB-26 half 2), so it must not cross the wire until that is taken.
    -- OBRAVNAVANO is TZ-naive holding UTC (same convention as USTVARJEN post-TB-14),
    -- so it takes the identical serializer as createdAt above.
    APEX_JSON.write('reviewedBy',   rec.obravnaval);
    APEX_JSON.write('reviewedAt',
      TO_CHAR(SYS_EXTRACT_UTC(CAST(rec.obravnavano AS TIMESTAMP WITH TIME ZONE)),
              'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));

    APEX_JSON.open_array('types');
    FOR t IN (
      SELECT skupina_koda, tip_koda
        FROM tb_motnje_tipi_dogodka
       WHERE motnja_id = rec.motnja_id
       ORDER BY skupina_koda, tip_koda
    ) LOOP
      APEX_JSON.open_object;
      APEX_JSON.write('groupCode', t.skupina_koda);
      APEX_JSON.write('typeCode',  t.tip_koda);
      APEX_JSON.close_object;
    END LOOP;
    APEX_JSON.close_array;

    APEX_JSON.open_array('observers');
    FOR o IN (
      SELECT ime_opazovalca
        FROM tb_motnje_opazovalci
       WHERE motnja_id = rec.motnja_id
       ORDER BY ime_opazovalca
    ) LOOP
      APEX_JSON.write(o.ime_opazovalca);
    END LOOP;
    APEX_JSON.close_array;

    APEX_JSON.open_array('photos');
    FOR p IN (
      SELECT foto_id, mime_type
        FROM tb_motnje_foto
       WHERE motnja_id = rec.motnja_id
       ORDER BY ustvarjen
    ) LOOP
      APEX_JSON.open_object;
      APEX_JSON.write('id',       p.foto_id);
      APEX_JSON.write('mimeType', p.mime_type);
      APEX_JSON.close_object;
    END LOOP;
    APEX_JSON.close_array;

    APEX_JSON.close_object;
  END LOOP;
  APEX_JSON.close_array;
  APEX_JSON.close_object;
  l_out := APEX_JSON.get_clob_output;
  APEX_JSON.free_output;

  :status_code  := 200;
  :content_type := 'application/json';
  -- Chunk-emit so HTP.prn never gets a CLOB it has to implicitly convert
  -- to VARCHAR2 (ORA-06502 above ~32 KB). Triggers on orgs with many records.
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

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '/',
    p_method => 'GET', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => '/',
    p_method => 'GET', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST disturbances/
  ----------------------------------------------------------------------------
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
  l_legal        VARCHAR2(200);
  l_case_status  VARCHAR2(30);
  l_proposed     VARCHAR2(500);
  l_obhod_id     VARCHAR2(36);
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
  l_legal        := APEX_JSON.get_varchar2(p_path => 'legalBasis');
  l_case_status  := APEX_JSON.get_varchar2(p_path => 'caseStatus');
  l_proposed     := APEX_JSON.get_varchar2(p_path => 'proposedType');
  l_obhod_id     := APEX_JSON.get_varchar2(p_path => 'obhodId');

  -- Defense in depth: older clients won't send caseStatus. The column is
  -- NOT NULL with DB-side default 'Odprto', and an INSERT with a NULL bind
  -- would fail the constraint - so substitute the default here.
  IF l_case_status IS NULL THEN
    l_case_status := 'Odprto';
  END IF;

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

  -- 4. Insert main record. obhod_id is the optional walk-around link;
  --    the FK on tb_motnje.obhod_id will surface ORA-02291 if the walk
  --    doesn't exist (caught by WHEN OTHERS -> 500). Clients should POST
  --    the walk before any of its disturbances.
  INSERT INTO tb_motnje (
    motnja_id, org_id, geo_sirina, geo_dolzina, natancnost_lok,
    cas_opazovanja, opis, ukrepanje, zakonska_podlaga, status_obravnave,
    predlog_tipa, obhod_id, ustvarjen_od
  ) VALUES (
    l_motnja_id, l_ctx.org_id, l_lat, l_lon, l_loc_acc,
    l_observed_at, l_description, l_action, l_legal, l_case_status,
    l_proposed, l_obhod_id, l_ctx.email
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
EXCEPTION
  WHEN OTHERS THEN
    -- Last-ditch guard so an unhandled exception never returns 200 with an
    -- empty body (which the client would mark as synced). Roll back any
    -- partial write and surface the real status.
    ROLLBACK;
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
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
  l_legal        VARCHAR2(200);
  l_case_status  VARCHAR2(30);
  l_proposed     VARCHAR2(500);
  l_obhod_id     VARCHAR2(36);
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
  l_legal        := APEX_JSON.get_varchar2(p_path => 'legalBasis');
  l_case_status  := APEX_JSON.get_varchar2(p_path => 'caseStatus');
  l_proposed     := APEX_JSON.get_varchar2(p_path => 'proposedType');
  l_obhod_id     := APEX_JSON.get_varchar2(p_path => 'obhodId');

  -- Older PUT-capable clients won't send caseStatus; preserve the existing
  -- DB row's value rather than NULLing it out. Easier than COALESCEing in SQL.
  IF l_case_status IS NULL THEN
    BEGIN
      SELECT status_obravnave INTO l_case_status
        FROM tb_motnje WHERE motnja_id = l_motnja_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_case_status := 'Odprto';
    END;
  END IF;

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
     SET geo_sirina       = l_lat,
         geo_dolzina      = l_lon,
         natancnost_lok   = l_loc_acc,
         cas_opazovanja   = l_observed_at,
         opis             = l_description,
         ukrepanje        = l_action,
         zakonska_podlaga = l_legal,
         status_obravnave = l_case_status,
         predlog_tipa     = l_proposed,
         obhod_id         = l_obhod_id,
         spremenjen_od    = l_ctx.email,
         spremenjen       = SYS_EXTRACT_UTC(SYSTIMESTAMP) -- UTC, see TB-14
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

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id',
    p_method => 'DELETE', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST disturbances/:id/photos/:photoId  (upload binary; idempotent on photoId)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id/photos/:photoId'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id/photos/:photoId',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_motnja_id    VARCHAR2(36) := :id;
  l_foto_id      VARCHAR2(36) := :photoId;
  l_existing_org NUMBER;
  l_existing_ph  NUMBER;
  l_blob         BLOB := :body;
  l_size         NUMBER;
  l_mime         VARCHAR2(80);
  l_status       PLS_INTEGER := 201;
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

  -- Confirm parent record exists and is ours. 404 if missing or cross-tenant.
  BEGIN
    SELECT org_id INTO l_existing_org
      FROM tb_motnje
     WHERE motnja_id = l_motnja_id;
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

  IF l_blob IS NULL OR DBMS_LOB.getlength(l_blob) = 0 THEN
    :status_code  := 400;
    :content_type := 'application/json';
    HTP.prn('{"error":"empty_body"}');
    RETURN;
  END IF;

  l_size := DBMS_LOB.getlength(l_blob);
  -- 10 MB hard cap. Compressed phone photos are ~200-500 KB so anything
  -- larger is almost certainly an uncompressed upload by mistake.
  IF l_size > 10485760 THEN
    :status_code  := 413;
    :content_type := 'application/json';
    HTP.prn('{"error":"payload_too_large","limit":10485760}');
    RETURN;
  END IF;

  -- ORDS doesn't let us bind two header params with the same name (we already
  -- bind Content-Type as OUT for the response), so we read the inbound type
  -- straight from the CGI env. Strip any "; charset=..." suffix.
  l_mime := LOWER(NVL(OWA_UTIL.get_cgi_env('CONTENT_TYPE'), 'image/jpeg'));
  IF INSTR(l_mime, ';') > 0 THEN
    l_mime := TRIM(SUBSTR(l_mime, 1, INSTR(l_mime, ';') - 1));
  END IF;
  IF l_mime NOT IN ('image/jpeg','image/png','image/webp','image/heic') THEN
    :status_code  := 415;
    :content_type := 'application/json';
    HTP.prn('{"error":"unsupported_mime","received":"' || REPLACE(l_mime, '"', '\"') || '"}');
    RETURN;
  END IF;

  -- Idempotency: same foto_id arriving again is a no-op (200), regardless of
  -- whether the bytes match. Lets the offline upload queue retry safely.
  SELECT COUNT(*) INTO l_existing_ph FROM tb_motnje_foto WHERE foto_id = l_foto_id;
  IF l_existing_ph > 0 THEN
    l_status := 200;
  ELSE
    INSERT INTO tb_motnje_foto (foto_id, motnja_id, vsebina, mime_type, velikost, ustvarjen_od)
    VALUES (l_foto_id, l_motnja_id, l_blob, l_mime, l_size, l_ctx.email);
    COMMIT;
  END IF;

  :status_code  := l_status;
  :content_type := 'application/json';
  HTP.prn('{"id":"' || l_foto_id || '","status":"'
          || CASE WHEN l_status = 201 THEN 'created' ELSE 'exists' END
          || '"}');
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

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'POST', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'POST', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');
  -- Inbound Content-Type is read via OWA_UTIL.get_cgi_env('CONTENT_TYPE') in
  -- the handler body. ORDS doesn't allow rebinding the same header name with
  -- a different access method.

  ----------------------------------------------------------------------------
  -- GET disturbances/:id/photos/:photoId  (download binary)
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id/photos/:photoId',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_motnja_id    VARCHAR2(36) := :id;
  l_foto_id      VARCHAR2(36) := :photoId;
  l_existing_org NUMBER;
  l_blob         BLOB;
  l_mime         VARCHAR2(80);
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

  -- Org-scoped lookup: photo must belong to a record owned by the caller.
  BEGIN
    SELECT m.org_id, f.vsebina, f.mime_type
      INTO l_existing_org, l_blob, l_mime
      FROM tb_motnje_foto f
      JOIN tb_motnje      m ON m.motnja_id = f.motnja_id
     WHERE f.foto_id   = l_foto_id
       AND f.motnja_id = l_motnja_id;
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

  :status_code  := 200;
  :content_type := l_mime;
  -- Same pattern APEX uses for BLOB downloads: hand the BLOB to WPG_DOCLOAD
  -- and let it stream back to the client in chunks.
  WPG_DOCLOAD.download_file(l_blob);
EXCEPTION
  WHEN OTHERS THEN
    :status_code  := 500;
    :content_type := 'application/json';
    HTP.prn('{"error":"server_error","sqlcode":' || SQLCODE
            || ',"sqlerrm":"' || REPLACE(SUBSTR(SQLERRM, 1, 400), '"', '\"') || '"}');
END;
~'
  );

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'GET', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'GET', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- DELETE disturbances/:id/photos/:photoId
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'narcis_disturbances',
    p_pattern     => ':id/photos/:photoId',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_ctx          pkg_tb_auth.t_auth_ctx;
  l_motnja_id    VARCHAR2(36) := :id;
  l_foto_id      VARCHAR2(36) := :photoId;
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
    SELECT m.org_id INTO l_existing_org
      FROM tb_motnje_foto f
      JOIN tb_motnje      m ON m.motnja_id = f.motnja_id
     WHERE f.foto_id   = l_foto_id
       AND f.motnja_id = l_motnja_id
       FOR UPDATE OF f.foto_id;
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

  DELETE FROM tb_motnje_foto WHERE foto_id = l_foto_id;
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

  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'DELETE', p_name => 'X-ORDS-STATUS-CODE',
    p_bind_variable_name => 'status_code', p_source_type => 'HEADER',
    p_param_type => 'INT', p_access_method => 'OUT');
  ORDS.DEFINE_PARAMETER(p_module_name => 'narcis_disturbances', p_pattern => ':id/photos/:photoId',
    p_method => 'DELETE', p_name => 'Content-Type',
    p_bind_variable_name => 'content_type', p_source_type => 'HEADER',
    p_param_type => 'STRING', p_access_method => 'OUT');

  COMMIT;
END;
/
