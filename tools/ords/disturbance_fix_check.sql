--------------------------------------------------------------------------------
-- One-shot fix: align CK_TB_MOTNJE_LOC with the values the Flutter form
-- actually sends ('Natančna' / 'Približna') instead of the lowercase ASCII
-- placeholders the schema script originally used.
--
-- Idempotent: drop-if-exists then re-add. No data migration needed because
-- TB_MOTNJE is currently empty (every prior insert failed with ORA-02290 -
-- see tb_motnje_debug for the trail).
--------------------------------------------------------------------------------

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE tb_motnje DROP CONSTRAINT ck_tb_motnje_loc';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -2443 THEN NULL;  -- ORA-02443 constraint does not exist
    ELSE RAISE;
    END IF;
END;
/

ALTER TABLE tb_motnje
  ADD CONSTRAINT ck_tb_motnje_loc
  CHECK (natancnost_lok IN ('Natančna','Približna'));
