--------------------------------------------------------------------------------
-- Walk-around (obhod) schema for the "Terenska beležka" (TB_) app.
--
-- A walk-around is a continuous GPS-tracked field session. While it is
-- active, any disturbance the user records is linked back to the walk
-- (TB_MOTNJE.OBHOD_ID) so the path and its observations can be reviewed
-- together later. Photos still hang off TB_MOTNJE; walks themselves don't
-- carry photos.
--
-- Tables:
--   TB_OBHODI         - one row per walk (start/end time, optional name/notes)
--   TB_OBHODI_TOCKE   - track points (lat/lon/time/accuracy), composite PK
--                       (OBHOD_ID, SEQ); ON DELETE CASCADE from TB_OBHODI
--
-- Plus an ALTER on TB_MOTNJE adding nullable OBHOD_ID + FK with
-- ON DELETE SET NULL so deleting a walk does not lose its disturbances.
--
-- PK strategy for TB_OBHODI: client-generated UUID (VARCHAR2(36)), same
-- pattern as TB_MOTNJE/TB_MOTNJE_FOTO so POST is naturally idempotent on
-- retry without a separate dedupe column.
--
-- Track-point ordering: SEQ is a 0-based monotonic integer assigned by the
-- client. Reading by (obhod_id, seq) reproduces the walk's path in capture
-- order. The PK is the only index needed for that.
--
-- ORG_ID strategy: derived server-side from the authenticated user's
-- NARCIS_UPORABNIKI.ORGANIZACIJA, identical to TB_MOTNJE.
--
-- Idempotent: each CREATE / ALTER is wrapped in a guard so the script can
-- be re-run. Drop the tables manually for a clean rebuild:
--     ALTER TABLE TB_MOTNJE DROP CONSTRAINT FK_TB_MOTNJE_OBHOD;
--     ALTER TABLE TB_MOTNJE DROP COLUMN OBHOD_ID;
--     DROP INDEX IX_TB_MOTNJE_OBHOD;
--     DROP TABLE TB_OBHODI_TOCKE PURGE;
--     DROP TABLE TB_OBHODI       PURGE;
--------------------------------------------------------------------------------

-- 1. Walks ------------------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_OBHODI';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_obhodi (
        obhod_id       VARCHAR2(36)   NOT NULL,
        org_id         NUMBER         NOT NULL,
        zacetek        TIMESTAMP      NOT NULL,
        konec          TIMESTAMP      NOT NULL,
        naziv          VARCHAR2(200)  NULL,
        opis           CLOB           NULL,
        ustvarjen_od   VARCHAR2(255)  NOT NULL,
        -- UTC wall-clock (TB-14): SYSTIMESTAMP stored local digits the GET
        -- handler then mislabels 'Z'; SYS_EXTRACT_UTC normalizes to UTC first.
        ustvarjen      TIMESTAMP      DEFAULT SYS_EXTRACT_UTC(SYSTIMESTAMP) NOT NULL,
        spremenjen_od  VARCHAR2(255)  NULL,
        spremenjen     TIMESTAMP      NULL,
        CONSTRAINT pk_tb_obhodi      PRIMARY KEY (obhod_id),
        CONSTRAINT fk_tb_obhodi_org  FOREIGN KEY (org_id)
                                     REFERENCES narcis_organizacije (id),
        CONSTRAINT ck_tb_obhodi_kon  CHECK (konec >= zacetek)
      )
    ~';
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_obhodi_org_zac ON tb_obhodi (org_id, zacetek DESC)';
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_obhodi_ustvarjen_od ON tb_obhodi (ustvarjen_od)';
  END IF;
END;
/

-- 2. Track points -----------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_OBHODI_TOCKE';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_obhodi_tocke (
        obhod_id     VARCHAR2(36)  NOT NULL,
        seq          NUMBER        NOT NULL,
        geo_sirina   NUMBER(10,7)  NOT NULL,
        geo_dolzina  NUMBER(10,7)  NOT NULL,
        cas          TIMESTAMP     NOT NULL,
        natancnost   NUMBER(10,2)  NULL,
        CONSTRAINT pk_tb_obhodi_tocke      PRIMARY KEY (obhod_id, seq),
        CONSTRAINT fk_tb_obhodi_tocke_obh  FOREIGN KEY (obhod_id)
                                           REFERENCES tb_obhodi (obhod_id)
                                           ON DELETE CASCADE,
        CONSTRAINT ck_tb_obhodi_tocke_lat  CHECK (geo_sirina  BETWEEN -90  AND 90),
        CONSTRAINT ck_tb_obhodi_tocke_lon  CHECK (geo_dolzina BETWEEN -180 AND 180),
        CONSTRAINT ck_tb_obhodi_tocke_seq  CHECK (seq >= 0),
        CONSTRAINT ck_tb_obhodi_tocke_acc  CHECK (natancnost IS NULL OR natancnost >= 0)
      )
    ~';
  END IF;
END;
/

-- 3. Link disturbances to their walk ----------------------------------------
-- Adds TB_MOTNJE.OBHOD_ID with FK ON DELETE SET NULL: deleting a walk keeps
-- the disturbances it captured, just unlinked. Index supports the "list
-- this walk's disturbances" query.
DECLARE
  l_col NUMBER;
  l_fk  NUMBER;
  l_ix  NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_col
    FROM user_tab_columns
   WHERE table_name = 'TB_MOTNJE' AND column_name = 'OBHOD_ID';
  IF l_col = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE tb_motnje ADD obhod_id VARCHAR2(36) NULL';
  END IF;

  SELECT COUNT(*) INTO l_fk
    FROM user_constraints
   WHERE table_name = 'TB_MOTNJE' AND constraint_name = 'FK_TB_MOTNJE_OBHOD';
  IF l_fk = 0 THEN
    EXECUTE IMMEDIATE q'~
      ALTER TABLE tb_motnje
        ADD CONSTRAINT fk_tb_motnje_obhod
        FOREIGN KEY (obhod_id)
        REFERENCES tb_obhodi (obhod_id)
        ON DELETE SET NULL
    ~';
  END IF;

  SELECT COUNT(*) INTO l_ix
    FROM user_indexes
   WHERE table_name = 'TB_MOTNJE' AND index_name = 'IX_TB_MOTNJE_OBHOD';
  IF l_ix = 0 THEN
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_motnje_obhod ON tb_motnje (obhod_id)';
  END IF;
END;
/

-- 4. TB-14: store TB_OBHODI.USTVARJEN default in UTC ------------------------
-- Same fix as disturbance_schema.sql §8: SYSTIMESTAMP stored the DB host's
-- LOCAL wall-clock into this TZ-naive column, which the GET handler then
-- mislabels 'Z' (createdAt read back +1/+2 h ahead). SYS_EXTRACT_UTC(
-- SYSTIMESTAMP) stores UTC. Idempotent: only ALTERs while the default still
-- lacks SYS_EXTRACT_UTC. Changes the default for NEW rows only; existing rows
-- are corrected by the run-once tools/ords/tb14_backfill_audit_ts_utc.sql.
DECLARE
  l_def VARCHAR2(4000);
BEGIN
  SELECT data_default INTO l_def
    FROM user_tab_columns
   WHERE table_name = 'TB_OBHODI' AND column_name = 'USTVARJEN';
  IF INSTR(UPPER(l_def), 'EXTRACT') = 0 THEN
    EXECUTE IMMEDIATE
      'ALTER TABLE tb_obhodi MODIFY (ustvarjen DEFAULT SYS_EXTRACT_UTC(SYSTIMESTAMP))';
  END IF;
END;
/

COMMIT;
