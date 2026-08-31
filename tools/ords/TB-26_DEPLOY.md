# TB-26 half 1 — ORDS deploy runbook

Widens `GET /ords/narcis/disturbances/` to return the back-office review stamp
(`reviewedBy`, `reviewedAt`) so the phone can show *who* closed a record and *when*,
not just the verdict.

**One file changes:** [`disturbance_endpoints.sql`](disturbance_endpoints.sql) — the
`GET /` handler only. No schema change, no new table, no new grant, no DDL.

## Prerequisites

- `TB_MOTNJE.OBRAVNAVAL` and `TB_MOTNJE.OBRAVNAVANO` must already exist. They were
  added by narcis-vibed `ords/vibed_trsca_ddl.sql` (NV-220) and have been live on
  prod since **2026-08-26**. If they are missing the handler raises `ORA-00904`.
  Read-only check:

  ```sql
  SELECT column_name, data_type
    FROM user_tab_columns
   WHERE table_name = 'TB_MOTNJE'
     AND column_name IN ('OBRAVNAVAL','OBRAVNAVANO')
   ORDER BY column_name;
  ```

  Expect exactly two rows: `OBRAVNAVAL VARCHAR2`, `OBRAVNAVANO TIMESTAMP(6)`.
  **If this returns fewer than two rows, stop** — deploy the narcis-vibed DDL first.

## Deploy

Prod Oracle is not reachable from the maintainer's machine (internal network), so this
runs in **APEX SQL Workshop → SQL Commands**, against the `NARCIS` schema, same as every
prior deploy in this repo.

1. Open `tools/ords/disturbance_endpoints.sql` and run the **whole file**. It is
   idempotent: `ORDS.DEFINE_MODULE` re-registers the module and its handlers in place.
2. Expect `PL/SQL procedure successfully completed.` with no `ORA-` errors.

Nothing else needs re-publishing — `pkg_tb_auth` is untouched, and the POST / PUT /
DELETE / photo handlers are byte-identical to what is already live.

## Verify (read-only, ~1 minute)

```bash
bash tools/ords/verify_tb26.sh
```

Prompts for the NarcIS password with hidden input (nothing reaches shell history), issues a
**single GET**, and writes nothing anywhere. It checks:

1. **HTTP 200 and the pre-existing payload intact** — no regression in the keys that were
   already there.
2. **Reviewed records carry both keys** — `reviewedBy` and a Z-tagged `reviewedAt`.
3. **`opombaUradna` is absent** from the raw bytes. Its presence would mean the wrong column
   list shipped.

An **unreviewed** record simply omits both keys (APEX_JSON elides NULLs) — correct, not a
failure. If *no* record carries a stamp the script says so rather than passing silently: that
is fine if the back office hasn't reviewed anything in your org, and a real failure if you
know it has.

**The one thing the script cannot settle, and you must eyeball.** It prints each review time
as both the UTC on the wire and the wall-clock the phone will show. Open the same record in
the web backoffice: the wall-clocks must **match**. A **1 h / 2 h** gap means `OBRAVNAVANO`
is not stored UTC after all and the serializer double-shifts — roll back and re-open TB-26.

## Deployment record

- **2026-08-31** — deployed to ARSO prod via APEX SQL Workshop (maintainer-run). Verified the same
  day with `verify_tb26.sh`: all checks pass, and the timezone proof reads −0.3 s … +1.0 s across the
  10 most recent walks (a shift would read ~3600 s / ~7200 s). `reviewedAt` confirmed honest UTC.

## Rollback

`git revert` the commit and re-run the whole file. The handler is stateless and the
change is read-only, so rollback is immediate and loses nothing.

## Client coupling — there is none, in either direction

The Flutter client reads both keys as optional (`json['reviewedBy'] as String?`), so:

- **App shipped before this deploy** → keys absent → the review pills simply don't render.
- **This deploy shipped before the app** → the extra keys are ignored by older builds.

Either order is safe; neither is a breaking change. TB-27 (status-coloured map dots)
needs no server change at all.
