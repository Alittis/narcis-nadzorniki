--------------------------------------------------------------------------------
-- Disturbance schema for the "Terenska beležka" (TB_) app.
--
-- Tables:
--   TB_SIF_MOTNJE_SKUPINE   - codebook of disturbance type GROUPS (universal)
--   TB_SIF_MOTNJE_TIPI      - codebook of disturbance TYPES (per-org additions
--                             allowed via ORG_ID; ORG_ID NULL = global)
--   TB_MOTNJE               - main disturbance records (one row per observation)
--   TB_MOTNJE_TIPI_DOGODKA  - junction: which type codes apply to a given record
--                             (intentionally NOT a FK to TB_SIF_MOTNJE_TIPI -
--                             historical records keep their type codes even if
--                             the codebook later changes/removes a row)
--   TB_MOTNJE_OPAZOVALCI    - junction: observers (free-text name + optional FK)
--   TB_MOTNJE_FOTO          - photos (BLOB content; PK is client-generated UUID
--                             so POST /disturbances/:id/photos/:photoId is
--                             idempotent on retry, same as the parent record)
--
-- PK strategy for TB_MOTNJE: client-generated UUID (VARCHAR2(36)). Off Oracle
-- convention but lets POST be naturally idempotent on retry without a
-- separate dedupe column. See ARCHITECTURE.md §12.
--
-- ORG_ID strategy: derived server-side from the authenticated user's
-- NARCIS_UPORABNIKI.ORGANIZACIJA column (single org per user). The client
-- never sends ORG_ID; the handler stamps it.
--
-- Idempotent: each CREATE is wrapped in a guard so the script can be re-run.
--   Drop the tables manually if you want a clean rebuild:
--     DROP TABLE TB_MOTNJE_FOTO          PURGE;
--     DROP TABLE TB_MOTNJE_OPAZOVALCI    PURGE;
--     DROP TABLE TB_MOTNJE_TIPI_DOGODKA  PURGE;
--     DROP TABLE TB_MOTNJE               PURGE;
--     DROP TABLE TB_SIF_MOTNJE_TIPI      PURGE;
--     DROP TABLE TB_SIF_MOTNJE_SKUPINE   PURGE;
--     DROP SEQUENCE TB_SIF_MOTNJE_TIPI_SEQ;
--------------------------------------------------------------------------------

-- 1. Group codebook ---------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_SIF_MOTNJE_SKUPINE';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_sif_motnje_skupine (
        skupina_koda  VARCHAR2(2)   NOT NULL,
        ime           VARCHAR2(200) NOT NULL,
        aktivna       CHAR(1)       DEFAULT 'Y' NOT NULL,
        CONSTRAINT pk_tb_sif_motnje_skupine PRIMARY KEY (skupina_koda),
        CONSTRAINT ck_tb_sif_skupine_akt    CHECK (aktivna IN ('Y','N'))
      )
    ~';
  END IF;
END;
/

-- 2. Type codebook ----------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_sequences WHERE sequence_name = 'TB_SIF_MOTNJE_TIPI_SEQ';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE tb_sif_motnje_tipi_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE';
  END IF;
END;
/

DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_SIF_MOTNJE_TIPI';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_sif_motnje_tipi (
        tip_id        NUMBER          NOT NULL,
        skupina_koda  VARCHAR2(2)     NOT NULL,
        tip_koda      VARCHAR2(4)     NOT NULL,
        ime           VARCHAR2(300)   NOT NULL,
        pojasnilo     VARCHAR2(2000)  NULL,
        org_id        NUMBER          NULL,
        aktiven       CHAR(1)         DEFAULT 'Y' NOT NULL,
        CONSTRAINT pk_tb_sif_motnje_tipi   PRIMARY KEY (tip_id),
        CONSTRAINT fk_tb_sif_tipi_skupina  FOREIGN KEY (skupina_koda)
                                           REFERENCES tb_sif_motnje_skupine (skupina_koda),
        CONSTRAINT fk_tb_sif_tipi_org      FOREIGN KEY (org_id)
                                           REFERENCES narcis_organizacije (id),
        CONSTRAINT ck_tb_sif_tipi_akt      CHECK (aktiven IN ('Y','N'))
      )
    ~';
    -- Function-based unique index so the same (group, type) pair can exist
    -- once globally (ORG_ID NULL) and once per organization. NVL maps NULL to
    -- 0, which is safe because narcis_organizacije.id is a positive sequence.
    EXECUTE IMMEDIATE q'~
      CREATE UNIQUE INDEX ux_tb_sif_motnje_tipi_scope
        ON tb_sif_motnje_tipi (skupina_koda, tip_koda, NVL(org_id, 0))
    ~';
  END IF;
END;
/

-- 3. Main records -----------------------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_MOTNJE';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_motnje (
        motnja_id        VARCHAR2(36)   NOT NULL,
        org_id           NUMBER         NOT NULL,
        geo_sirina       NUMBER(10,7)   NOT NULL,
        geo_dolzina      NUMBER(10,7)   NOT NULL,
        natancnost_lok   VARCHAR2(20)   NOT NULL,
        cas_opazovanja   TIMESTAMP      NOT NULL,
        opis             CLOB           NULL,
        ukrepanje        VARCHAR2(50)   NOT NULL,
        predlog_tipa     VARCHAR2(500)  NULL,
        ustvarjen_od     VARCHAR2(255)  NOT NULL,
        ustvarjen        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
        spremenjen_od    VARCHAR2(255)  NULL,
        spremenjen       TIMESTAMP      NULL,
        CONSTRAINT pk_tb_motnje      PRIMARY KEY (motnja_id),
        CONSTRAINT fk_tb_motnje_org  FOREIGN KEY (org_id)
                                     REFERENCES narcis_organizacije (id),
        CONSTRAINT ck_tb_motnje_lat  CHECK (geo_sirina  BETWEEN -90  AND 90),
        CONSTRAINT ck_tb_motnje_lon  CHECK (geo_dolzina BETWEEN -180 AND 180),
        CONSTRAINT ck_tb_motnje_loc  CHECK (natancnost_lok IN ('Natančna','Približna'))
      )
    ~';
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_motnje_org_cas ON tb_motnje (org_id, cas_opazovanja DESC)';
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_motnje_ustvarjen_od ON tb_motnje (ustvarjen_od)';
  END IF;
END;
/

-- 4. Junction: types per record ---------------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_MOTNJE_TIPI_DOGODKA';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_motnje_tipi_dogodka (
        motnja_id     VARCHAR2(36) NOT NULL,
        skupina_koda  VARCHAR2(2)  NOT NULL,
        tip_koda      VARCHAR2(4)  NOT NULL,
        CONSTRAINT pk_tb_motnje_tipi_dog  PRIMARY KEY (motnja_id, skupina_koda, tip_koda),
        CONSTRAINT fk_tb_motnje_tipi_mot  FOREIGN KEY (motnja_id)
                                          REFERENCES tb_motnje (motnja_id)
                                          ON DELETE CASCADE
      )
    ~';
  END IF;
END;
/

-- 5. Junction: observers per record -----------------------------------------
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_MOTNJE_OPAZOVALCI';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_motnje_opazovalci (
        motnja_id       VARCHAR2(36)  NOT NULL,
        ime_opazovalca  VARCHAR2(200) NOT NULL,
        uporabnik_id    NUMBER        NULL,
        CONSTRAINT pk_tb_motnje_opazovalci  PRIMARY KEY (motnja_id, ime_opazovalca),
        CONSTRAINT fk_tb_motnje_opaz_mot    FOREIGN KEY (motnja_id)
                                            REFERENCES tb_motnje (motnja_id)
                                            ON DELETE CASCADE,
        CONSTRAINT fk_tb_motnje_opaz_upor   FOREIGN KEY (uporabnik_id)
                                            REFERENCES narcis_uporabniki (id)
      )
    ~';
  END IF;
END;
/

-- 6. Photos -----------------------------------------------------------------
-- Photo BLOBs live alongside the disturbance record. PK is a client-generated
-- UUID so POST /disturbances/:id/photos/:photoId is idempotent on retry, same
-- pattern as the parent record. The client compresses photos before upload
-- (image_picker maxWidth=1600, quality=85) so VELIKOST is typically < 500 KB.
DECLARE
  l_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_exists FROM user_tables WHERE table_name = 'TB_MOTNJE_FOTO';
  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE q'~
      CREATE TABLE tb_motnje_foto (
        foto_id        VARCHAR2(36)   NOT NULL,
        motnja_id      VARCHAR2(36)   NOT NULL,
        vsebina        BLOB           NOT NULL,
        mime_type      VARCHAR2(80)   DEFAULT 'image/jpeg' NOT NULL,
        velikost       NUMBER         NOT NULL,
        ustvarjen      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
        ustvarjen_od   VARCHAR2(255)  NOT NULL,
        CONSTRAINT pk_tb_motnje_foto       PRIMARY KEY (foto_id),
        CONSTRAINT fk_tb_motnje_foto_mot   FOREIGN KEY (motnja_id)
                                           REFERENCES tb_motnje (motnja_id)
                                           ON DELETE CASCADE,
        CONSTRAINT ck_tb_motnje_foto_size  CHECK (velikost > 0),
        CONSTRAINT ck_tb_motnje_foto_mime  CHECK (mime_type IN ('image/jpeg','image/png','image/webp','image/heic'))
      )
      LOB (vsebina) STORE AS SECUREFILE (
        ENABLE STORAGE IN ROW
      )
    ~';
    -- Note: COMPRESS LOW / DEDUPLICATE were considered but require the
    -- Advanced Compression option license (ORA-00439). JPEGs are already
    -- compressed so plain SECUREFILE storage is the right default; revisit
    -- if Advanced Compression is later licensed on this database.
    EXECUTE IMMEDIATE 'CREATE INDEX ix_tb_motnje_foto_mot ON tb_motnje_foto (motnja_id)';
  END IF;
END;
/

COMMIT;
