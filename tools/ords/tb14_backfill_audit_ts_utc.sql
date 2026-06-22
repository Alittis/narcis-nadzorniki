--------------------------------------------------------------------------------
-- TB-14 — one-time backfill: correct existing server-stamped audit timestamps
--          (USTVARJEN / SPREMENJEN) from DB-host LOCAL wall-clock to UTC.
--
-- WHY -------------------------------------------------------------------------
-- USTVARJEN/SPREMENJEN were stamped from SYSTIMESTAMP (the DB host's LOCAL zoned
-- time, Europe/Ljubljana) into TZ-naive TIMESTAMP columns, so the stored digits
-- are LOCAL. The GET handler serialises every timestamp as UTC ('...Z'), so
-- createdAt reads back +1 h (CET) / +2 h (CEST) ahead of the true instant.
-- The schema default + PUT handlers are fixed forward (disturbance_schema.sql
-- §8, walks_schema.sql §4, *_endpoints.sql spremenjen). THIS script corrects the
-- rows that were written BEFORE that fix.
--
-- The conversion FROM_TZ(col,'Europe/Ljubljana') reinterprets the stored digits
-- as Ljubljana local *with the correct DST offset for each row's own date*
-- (+1 in winter, +2 in summer), then SYS_EXTRACT_UTC normalises to UTC. So it is
-- correct for both CET and CEST rows — do NOT replace it with a flat "- 2h".
--
-- ⚠ RUN EXACTLY ONCE. This is NOT idempotent: re-running subtracts the offset a
--   second time. Section A tells you whether it has already been applied — run
--   it first and READ IT before running Section B.
--
-- ORDER (low-/no-write maintenance window):
--   1. THIS script (Section A → confirm → Section B → Section C).   ← existing rows
--   2. Re-deploy disturbance_schema.sql + walks_schema.sql.         ← flips default
--   3. Re-deploy disturbance_endpoints.sql + walks_endpoints.sql.   ← spremenjen fix
--   Running this first (while every row is still LOCAL) keeps the transform
--   uniform. A handful of rows inserted between steps 1–2 would keep the old
--   local default; re-run Section A afterwards and, if any walk still shows a
--   ~+1/+2 h offset, correct just those (see the NOTE at the end).
--------------------------------------------------------------------------------

-- ============================================================================
-- SECTION A — PRE-FLIGHT (read-only). Confirms the offset and whether already done.
-- ============================================================================

-- A1. Session/DB time zone + the live local-vs-UTC gap right now.
SELECT DBTIMEZONE            AS db_tz,
       SESSIONTIMEZONE       AS session_tz,
       TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZH:TZM') AS systimestamp_now,
       ROUND((CAST(SYSTIMESTAMP AS DATE)
              - CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE)) * 24, 2) AS host_offset_hours
  FROM dual;
-- host_offset_hours should read 2 (CEST, summer) or 1 (CET, winter).

-- A2. Walks: createdAt vs endedAt. This is the canonical "applied?" signal.
--     NOT YET applied  -> hours_created_minus_ended ≈ +1 / +2 (host offset).
--     ALREADY applied  -> ≈ 0 (just the seconds/minutes between walk-end and POST).
SELECT obhod_id,
       TO_CHAR(konec,     'YYYY-MM-DD HH24:MI:SS') AS ended_stored,
       TO_CHAR(ustvarjen, 'YYYY-MM-DD HH24:MI:SS') AS created_stored,
       ROUND((CAST(ustvarjen AS DATE) - CAST(konec AS DATE)) * 24, 2)
                                                   AS hours_created_minus_ended
  FROM tb_obhodi
 ORDER BY zacetek DESC
 FETCH FIRST 10 ROWS ONLY;

-- A3. Row counts that Section B will touch.
SELECT 'tb_motnje.ustvarjen'        AS col, COUNT(*) AS rows_total,
       COUNT(spremenjen)            AS rows_with_spremenjen FROM tb_motnje
UNION ALL
SELECT 'tb_obhodi.ustvarjen',  COUNT(*), COUNT(spremenjen)  FROM tb_obhodi
UNION ALL
SELECT 'tb_motnje_foto.ustvarjen', COUNT(*), NULL           FROM tb_motnje_foto;

-- ============================================================================
-- SECTION B — BACKFILL (writes). Run only after Section A confirms NOT-yet-applied.
-- ============================================================================
UPDATE tb_motnje
   SET ustvarjen = SYS_EXTRACT_UTC(FROM_TZ(ustvarjen, 'Europe/Ljubljana'));
UPDATE tb_motnje
   SET spremenjen = SYS_EXTRACT_UTC(FROM_TZ(spremenjen, 'Europe/Ljubljana'))
 WHERE spremenjen IS NOT NULL;

UPDATE tb_obhodi
   SET ustvarjen = SYS_EXTRACT_UTC(FROM_TZ(ustvarjen, 'Europe/Ljubljana'));
UPDATE tb_obhodi
   SET spremenjen = SYS_EXTRACT_UTC(FROM_TZ(spremenjen, 'Europe/Ljubljana'))
 WHERE spremenjen IS NOT NULL;

UPDATE tb_motnje_foto
   SET ustvarjen = SYS_EXTRACT_UTC(FROM_TZ(ustvarjen, 'Europe/Ljubljana'));

COMMIT;

-- ============================================================================
-- SECTION C — VERIFY (read-only). Re-run A2: hours_created_minus_ended should
--             now be ≈ 0 for every walk. If it still shows ~+1/+2, STOP and
--             investigate (do not re-run Section B blindly).
-- ============================================================================
SELECT obhod_id,
       TO_CHAR(konec,     'YYYY-MM-DD HH24:MI:SS') AS ended_stored,
       TO_CHAR(ustvarjen, 'YYYY-MM-DD HH24:MI:SS') AS created_stored,
       ROUND((CAST(ustvarjen AS DATE) - CAST(konec AS DATE)) * 24, 2)
                                                   AS hours_created_minus_ended
  FROM tb_obhodi
 ORDER BY zacetek DESC
 FETCH FIRST 10 ROWS ONLY;

-- NOTE — if 'Europe/Ljubljana' raises ORA-01882 (region not recognised on this
-- DB), substitute 'CET' in the FROM_TZ calls: Oracle's 'CET' region observes the
-- same CET/CEST DST rules, so the result is identical for Slovenian timestamps.
