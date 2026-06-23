# Backlog — Terenska beležnica

Single source of truth for feedback, bugs, and tasks. Read at the start of every
session, alongside the other `project/*` docs. Seeded 2026-06-03 from the May 2026
field-test feedback (`Vtisi testne aplikacije motenj`).

## How this works

- **ID** — `TB-N`, stable and never reused. The number matches the order items were
  first captured; new items take the next free number.
- **Type** — `🐞 Bug` · `✨ Enhancement` · `❓ Needs discussion` · `🔧 Chore`
- **Priority** — `P1` soon · `P2` planned · `P3` nice-to-have
- **Status** — `Triage` → `Todo` → `Doing` → `Blocked` → `Done`
  - `Blocked` = waiting on a decision; the open question lives in the item's
    **Discussion** field. Resolve it in a session, write the answer there, flip to `Todo`.
- **Lifecycle** — capture (`Triage`) → set type + priority → `Todo` or `Blocked` →
  `Doing` → `Done`. When an item ships, its commit message starts with `TB-N:` so the
  backlog and git history point at each other. Done items stay below for traceability.
- **Priorities below are a draft** proposed by Claude — overrule freely.

---

## Open

### TB-2 · Edit / delete disturbance entries
`🐞 Bug` · `P1` · `Todo` · Reporter: Matjaž · Updated: 2026-06-03
- **Problem:** In the field, one disturbance was logged several times instead of once
  (reporter suspects weak signal or low battery). There is no way to correct it afterward.
- **Want:** Edit and delete entries from the profile → *Seznam zapisov* list.
- **Context:** Server PUT/DELETE `disturbances/:id` already exist and are smoke-tested
  (ARCHITECTURE §9.3); [`record_list_screen.dart`](../lib/screens/record_list_screen.dart)
  already lists the user's own records. Two distinct sub-tasks:
  1. **Root-cause the duplication.** POST is idempotent on the client UUID, so duplicates
     mean the client minted *multiple* records (multiple UUIDs) — likely a double-tap on
     save or a retry that re-generated the id. Reproduce before fixing.
  2. **Surface edit/delete in the UI.** Note the known gap: `AppState.updateRecord` /
     `deleteRecord` only reach Oracle when `isOnline && canSync` — offline edits/deletes
     are **not** queued (ARCHITECTURE §8, OPERATIONS §10). Decide whether this item also
     closes that gap or just exposes online edit/delete.
- **Discussion:** —
- **Shipped:** —

### TB-3 · Patrol path accuracy
`🐞 Bug` · `P2` · `Done` (shipped 1.3.1+12) · Reporters: Tomaž, Matjaž · Updated: 2026-06-22
- **Problem:** Walk (obhod) track points scatter off the actual road/path even with good
  GPS reception. Sample bad track received 2026-06-22 (zigzag / V-dips off a forest road).
- **Context:** The *recorded* track is captured in the background isolate
  [`walk_task_handler.dart`](../lib/services/walk_task_handler.dart) (not `home_screen.dart`,
  whose stream only drives the live user dot + halo). Each accepted fix is stored raw and
  POSTed once at walk end (`walks/` — points are write-once server-side; the `NATANCNOST`
  column keeps each point's accuracy). The home map draws the polyline by connecting raw
  points 1:1 in `_buildPolylines` ([`home_screen.dart`](../lib/screens/home_screen.dart)) —
  no smoothing or simplification.
- **Root cause (2026-06-22):** Three things compound:
  1. **Accuracy gate too lenient.** `_maxAccuracyMeters = 50` ([`walk_task_handler.dart:42`](../lib/services/walk_task_handler.dart))
     accepts any fix with reported horizontal error ≤ 50 m. That gate was calibrated to reject
     wifi/cell triangulation (ARCHITECTURE §Walk-tick filter), not to guarantee footpath-level
     precision. Under forest canopy, 20–45 m *real GPS* fixes are routine — they pass the gate
     and plot well off the path.
  2. **"Good reception" ≠ good accuracy.** The reporter's "dober sprejem" reflects
     satellites-in-view; `Position.accuracy` (the 68 % confidence radius, inflated by canopy
     multipath) is what governs scatter. Per-point accuracy is recorded but only used to size
     the dot halo, never to gate the recorded track.
  3. **No smoothing/simplification.** Points are connected raw; with a 5 m `distanceFilter`
     the lateral jitter is on the order of the step size, so the line weaves.
  - **Nuance:** Some off-path excursions are *real* — the supervisor stepping off the road to
    a disturbance (note the V-dips toward the red markers in the sample). Aggressive hard
    filtering / snap-to-road would wrongly erase legitimate detours; prefer a relative accuracy
    gate + gentle smoothing over a hard cliff.
- **Empirical (2026-06-22, pulled via ORDS `GET /walks` + `/points`; 7 walks ≥30 pts, 3190 fixes):**
  The problem is **bimodal**, which is exactly why users say "occasionally":
  - **6 of 7 walks are clean** — median accuracy 4–8 m, p90 ≤ 10 m, ≈0 % of fixes over 15 m, ~0
    positional jumps. No problem here.
  - **1 walk was pathological** (branka, 2026-05-05, 2488 pts): median **24 m**, p90 **44 m**, max
    pinned at the 50 m gate ceiling; **76 %** of fixes > 15 m, **48 %** > 25 m; ~400 implied teleports
    (>2.5 m/s) and ~840 zig-zag reversals. The whole walk rode at the ceiling — a phone stuck on
    coarse/fused location or a route under unbroken canopy, not random jitter. (The 5 m distanceFilter
    also inflates the point count: noise keeps tripping the 5 m threshold while barely moving.)
  - A **≈20 m gate cleanly separates the two populations**: clean walks lose ≈0 %, the bad walk loses
    the majority. Teleport-segment endpoints skew worse (median 26 m) than calm ones (17 m), so scatter
    tracks accuracy as expected.
  - **Implication:** the 50 m gate is the main miss — calibrated to reject wifi/cell, not to guarantee
    path precision, so it passed an entire ceiling-riding walk. Filter at **render time** (keep raw on
    the server — points are write-once and the honest record matters), not at capture.
- **Recommended approach (was option b, now data-backed):** render-time accuracy filter at ≈20 m +
  gentle polyline smoothing/simplification on the survivors; raise capture to
  `LocationAccuracy.bestForNavigation` (forces continuous GNSS — heads off the coarse-location case for
  future walks); optionally a per-walk "GPS was weak" indicator so a ceiling-riding track isn't drawn as
  authoritative. Not snap-to-road (heavy, external dep, and it would erase the real off-path detours to
  disturbances). Diagnostic data + scripts in the session scratchpad (`narcis-walks/`).
- **Implemented (2026-06-22, in source — pending commit + release build):** New pure helper
  [`track_polish.dart`](../lib/services/track_polish.dart) (`polishTrack`): drops fixes > 20 m accuracy
  (null-accuracy fixes kept), then a centred moving average (window 5) over the survivors. Wired into
  both map views — `_buildPolylines` (active + historical) in
  [`home_screen.dart`](../lib/screens/home_screen.dart) and the detail map in
  [`walk_detail_screen.dart`](../lib/screens/walk_detail_screen.dart), each guarded so a track that
  collapses below 2 points isn't drawn. Recording stream bumped to `LocationAccuracy.bestForNavigation`
  ([`walk_task_handler.dart`](../lib/services/walk_task_handler.dart)). Raw points untouched (write-once,
  so the change is tunable/reversible). Validated on real data: the 20 m cut keeps 100 % of the 6 clean
  walks and 40 % (1001/2488) of the pathological one. 7 new unit tests
  ([`test/track_polish_test.dart`](../test/track_polish_test.dart)); `flutter analyze` clean (no new
  issues), suite 50/50. ARCHITECTURE §Walk-tick filter updated. Deferred (not in this scope): the
  per-walk "GPS was weak" indicator.
- **Shipped:** Built into **v1.3.1+12** (2026-06-22, archived `~/Releases/terenska-beleznica-1.3.1+12.aab`);
  rolled out on the Play Closed testing track 2026-06-22 (v1.3.1+12). (Committed earlier as `d9aec82`.)

### TB-4 · Default disturbance location to the device's current position
`✨ Enhancement` · `P2` · `Todo` (quick win) · Reporters: Tomaž, Matjaž · Updated: 2026-06-22
- **Problem:** Setting an accurate location takes two manual steps — the app offers an
  approximate point, the satellite icon refines it (step 1), and a manual map tap gives the
  exact spot (step 2).
- **Related symptom (raised 2026-06-22, maintainer):** On the disturbance form's "Karta"
  picker the blue GPS dot and the red selection marker don't always overlap on open. Same root
  cause — the picker seeds the red marker from the map's viewport centre, not the live device
  fix — so this is folded in here rather than a separate item.
- **Want:** Make step 1 automatic so the new entry defaults to the phone's current position
  (the blue device dot); keep the manual map tap as an optional fine-tune. Tomaž's wording:
  "the app should first offer, as the disturbance location, the location where the phone is
  at that moment." **Acceptance:** the picker's red marker sits on the blue dot on open and
  diverges only once the user taps to fine-tune (post-tap divergence is intentional — the
  disturbance may be off the path from where they stand).
- **Context:** Entry/refine flow lives in [`form_screen.dart`](../lib/screens/form_screen.dart)
  and [`location_picker_screen.dart`](../lib/screens/location_picker_screen.dart);
  `locationAccuracy` is `Natančna` / `Približna`. The non-overlap is concrete: `_pickLocation`
  ([`form_screen.dart:134`](../lib/screens/form_screen.dart)) opens the picker with
  `initialLocation = _pickedOnMap ? _location : widget.mapCenter` — the **map centre**, not the
  device fix (even though `_location` was itself seeded from `initialLocation` at "+" time). The
  picker fetches the blue dot independently via `_refreshUserLocation`
  ([`location_picker_screen.dart`](../lib/screens/location_picker_screen.dart)), so red = map
  centre and blue = live GPS. Fix = seed the picker's marker from the live fix (pass the device
  location through instead of `mapCenter`). The live fix already exists on the home map
  ([`home_screen.dart`](../lib/screens/home_screen.dart) `[gps]` stream). Self-contained UX change.
- **Discussion:** Is the non-overlap on purpose? Initially no (they should coincide); after a
  manual tap yes (the offset is deliberate). This enhancement makes them overlap on open without
  removing the fine-tune.
- **Shipped:** —

### TB-6 · Show/hide historical entries on the map (visibility toggle)
`✨ Enhancement` · `P2` (quick win) · `Todo` · Reporters: Tomaž, Rudi · Updated: 2026-06-22
- **Problem:** In places there are so many historical points that they obscure the map and hurt
  readability.
- **Want:** A show/hide toggle for historical-entry points, so the map can be decluttered on demand.
- **Context:** The home map already layers the org's `Motnje` records and the bundled legacy set
  (`assets/legacy/notranjski_park_2025.json`, 703 rows) and has a chip-toggle pattern (basemap, Parcele,
  Obhodi) to copy — see [`home_screen.dart`](../lib/screens/home_screen.dart). This is the cheap,
  high-daily-value half; ship it first.
- **Discussion:** Split on 2026-06-22 from the original combined feedback (toggle + filter); the
  year/reporter/category filtering moved to TB-18 (larger build).
- **Shipped:** —

### TB-8 · Pause / resume an active patrol
`✨ Enhancement` · `P2` · `Todo` · Reporter: Damjan Intihar · Updated: 2026-06-03
- **Problem:** A supervisor patrols several locations in one day with other duties in
  between; today the only controls are start and end. Damjan worked around it by recording
  several separate walks.
- **Want:** A pause (temporary stop) of point recording between start and end, within a
  single walk.
- **Context:** Purely client-side — `TB_OBHODI` start/end and points are write-once on the
  server, and points are only POSTed at walk end (STATE.json `walks_schema`). So a pause is
  just "stop appending track points while paused, keep the session open" in
  [`home_screen.dart`](../lib/screens/home_screen.dart) / [`app_state.dart`](../lib/state/app_state.dart).
  No backend change. Decide how a gap renders in the track polyline (break vs. straight line).
- **Discussion:** —
- **Shipped:** —

### TB-9 · NULL entry — record a patrol with no disturbances
`❓ Needs discussion` · `P3` · `Blocked` · Reporter: Rudi · Updated: 2026-06-03
- **Problem:** On a patrol where nothing is found, there is no way to record the *absence* of
  disturbances. Over repeat visits to the same points, "when there were none" is itself useful
  data.
- **Context:** A walk with zero linked disturbances is already representable (`disturbanceCount`
  can be 0). Open question is the data model: is a zero-disturbance walk enough, or do they
  want an explicit "no disturbance observed" marker at specific recurring points?
- **Discussion:** Clarify the unit of "nothing here" — per walk, or per monitored point? That
  decision drives whether this is a UI affordance over existing walks or a new record kind.
- **Shipped:** —

### TB-12 · Search the disturbance-type codebook
`✨ Enhancement` · `P2` · `Todo` · Reporter: Matjaž · Updated: 2026-06-22
- **Problem:** Picking a disturbance type means scrolling 19 collapsible groups and expanding the
  right one to reach its types — **172 types** in all. Without already knowing which group a type
  lives under, finding it is slow, and it's done on every disturbance entry.
- **Want:** A search box ("iskalnik") on the type-selection screen (*šifrant motenj*) that filters
  the list as you type, so a few letters jump straight to the matching type(s).
- **Context:** Selection UI is [`type_selection_screen.dart`](../lib/screens/type_selection_screen.dart) —
  a `ListView` of per-group `ExpansionTile`s, each expanding to `CheckboxListTile`s rendered as
  `'${type.code}. ${type.name}'` with an optional `note` subtitle. Data is the const
  `disturbanceTypeGroups` (19 groups, 172 types total) in
  [`disturbance_types.dart`](../lib/data/disturbance_types.dart); each `DisturbanceType` has
  `code` / `name` / optional `note`, each group `code` / `name`. Multi-select is held in `_selected`
  keyed `'${groupCode}_${typeCode}'`, so a search only needs to narrow what's rendered while
  preserving that selection map. Self-contained client-side change — no backend, no model change.
- **Discussion:** Two design calls for the implementation thread: **(1) layout** — filter to a flat
  results list of matching types (fastest to scan, loses group framing) vs. keep the grouped layout
  but auto-expand groups that contain matches and hide non-matching types; **(2) match fields** —
  type name at minimum, optionally group name / code / `note`. Recommend matching type + group name,
  **accent- and case-insensitive** (so "sneman" finds "Snemanje", and č/š/ž fold) since that's how
  the wardens will type.
- **Shipped:** —

### TB-13 · Timestamps show in UTC, not local time, on synced records & walks
`🐞 Bug` · `P1` · `Done` (shipped 1.3.1+12) · Reporter: Matjaž · Updated: 2026-06-22
- **Problem:** The time shown for a disturbance / walk is not always local — it can read ~1–2 h off
  (the UTC offset; CET = +1, CEST = +2). The *recording* is fine; the **display** is wrong for any
  record/walk that has come back from the server.
- **Root cause (confirmed 2026-06-22):** The server returns `Z`-tagged UTC (sampled walk
  `startedAt`/`endedAt` and point `t` all end in `Z`), so parsing is correct — the bug is purely
  display-side. Times are POSTed as UTC
  (`toUtc().toIso8601String()` — [`remote_api.dart:449`](../lib/data/remote_api.dart) walks,
  [`:474`](../lib/data/remote_api.dart) disturbances) and the server stores/echoes that UTC instant.
  On read, `DateTime.parse` yields a UTC `DateTime` ([`remote_api.dart:123`](../lib/data/remote_api.dart),
  [`:221`](../lib/data/remote_api.dart)), but the display formatters call `DateFormat.format(...)`
  **without `.toLocal()`**, so they render the UTC wall-clock. Affected sites:
  [`detail_screen.dart:428`](../lib/screens/detail_screen.dart),
  [`record_list_screen.dart:43`](../lib/screens/record_list_screen.dart),
  [`walk_detail_screen.dart:204`](../lib/screens/walk_detail_screen.dart) (start/end) & `:262` (linked
  record), [`walks_list_screen.dart:44`](../lib/screens/walks_list_screen.dart). The tell:
  [`legacy_detail_screen.dart:15`](../lib/screens/legacy_detail_screen.dart) already does `.toLocal()`
  correctly — the live screens were never given the same treatment.
- **Why "not always":** a freshly created record/walk is still a *local* `DateTime` in memory, and the
  local-store round-trip preserves local (it serialises without `toUtc` —
  [`disturbance.dart:98`](../lib/models/disturbance.dart), [`walk.dart:118`](../lib/models/walk.dart)),
  so it shows the right time — until it's pulled back from the server, after which the same item flips
  to UTC. Teammates' records (always pulled) always show UTC.
- **Want:** Displayed times in local time everywhere.
- **Fix shape (confirmed):** Server already sends `Z`-tagged UTC, so no parse-boundary work is needed —
  just add `.toLocal()` at the five display sites above (matching
  [`legacy_detail_screen.dart:15`](../lib/screens/legacy_detail_screen.dart)), plus a round-trip test.
  Pure client change, no DB change. **Caveat:** do *not* blanket-`.toLocal()` the server `createdAt` — it's
  mislabeled (see TB-14), so converting it would double-offset.
- **Implemented (2026-06-22, merged to `main` via PR #4, `c70a4da` — pending release build):** Added `.toLocal()` at the
  display sites — `observedAt`/`startedAt`/`endedAt` only, never `createdAt` (TB-14 caveat respected). A
  grep sweep found **six** sites, one more than the root-cause list above: the fifth file
  [`walks_list_screen.dart`](../lib/screens/walks_list_screen.dart) formats `startedAt` in *two* places —
  the title fallback (`:44`) **and** the `_subtitle` helper (`:65`); both fixed. Full set:
  [`detail_screen.dart:428`](../lib/screens/detail_screen.dart),
  [`record_list_screen.dart:43`](../lib/screens/record_list_screen.dart),
  [`walk_detail_screen.dart`](../lib/screens/walk_detail_screen.dart) start/end (`:204`–`:205`) + linked
  record (`:262`), [`walks_list_screen.dart`](../lib/screens/walks_list_screen.dart) `:44` + `:65`. The two
  `form_screen.dart` `.format(...)` sites are correctly untouched — a `TimeOfDay` (`:405`) and the
  user-entered working `_date` (`:662`), neither a server round-trip. Round-trip test added
  ([`test/remote_api_test.dart`](../test/remote_api_test.dart), group `timestamp round-trip (TB-13)`):
  pins that a `Z`-tagged `observedAt` parses to a UTC instant and that a local→UTC-wire→parse→`toLocal`
  round-trip recovers the original wall-clock (TZ-independent — `toUtc`/`toLocal` are inverses).
  `flutter analyze` clean (no new issues); suite **52/52** (was 50). ARCHITECTURE §9.3 wire-payload note
  updated with the UTC-on-wire/local-in-UI invariant + the TB-14 caveat. (Display fix only — no widget-level
  render assertion, which on a UTC CI machine couldn't distinguish the bug anyway.)
- **Shipped:** Built into **v1.3.1+12** (2026-06-22, archived `~/Releases/terenska-beleznica-1.3.1+12.aab`);
  rolled out on the Play Closed testing track 2026-06-22 (v1.3.1+12). (Merged earlier as `c70a4da`, PR #4.)

### TB-14 · Server `createdAt` is stored in local time, mislabeled as UTC
`🐞 Bug` · `P2` · `Done` (deployed + verified on prod 2026-06-22) · Reporter: maintainer (discovered during TB-13, 2026-06-22) · Updated: 2026-06-22
- **Problem:** The server-assigned `createdAt` audit timestamp is the server's **local** wall-clock
  (Europe/Ljubljana) but serialized with a trailing `Z` as if UTC — so it isn't a true instant.
- **Evidence (confirmed 2026-06-22):** Across all 21 pulled walks, `createdAt` = `endedAt` + **exactly
  +2.00 h** (the CEST offset). `createdAt` isn't in the client `_walkPayload`
  ([`remote_api.dart:447`](../lib/data/remote_api.dart)) — it's set server-side at insert and equals the
  POST instant (right after `endedAt`), so the +2 h can only be the DB/handler stamping local time and
  labelling it `Z`. (All samples fall in the DST window, hence uniformly +2; a winter record should show
  +1, which would further confirm "server-local offset" rather than a fixed shift.)
- **Want:** `createdAt` returned as a genuine UTC instant (matching the `Z` label).
- **Context:** Likely the `CAS`/created column default (`SYSTIMESTAMP`/`CURRENT_TIMESTAMP` in the DB's
  local session TZ) or the ORDS/APEX serialization. Fix is **backend** — e.g. default to
  `SYS_EXTRACT_UTC(SYSTIMESTAMP)` or store/normalize to UTC in the handler so the `Z` is honest. Per the
  manual-deploy model this is deploy-ready SQL + runbook for the maintainer to run, not a live DB change.
  Verify the same on the disturbance side (`TB_MOTNJE` created column) with a `disturbances/` pull —
  client-supplied `observedAt` is fine (we send true UTC); only **server-defaulted** timestamps are suspect.
- **Impact:** Currently **latent** — `createdAt` isn't shown in the UI (display uses `observedAt` /
  walk start-end), so no user-visible error today. But the stored audit time is wrong by the local offset
  and will mislead the moment anything trusts or displays it (and would double-offset if `.toLocal()`'d —
  see TB-13 caveat).
- **Root cause (confirmed in source 2026-06-22):** Three server-stamped columns default/assign from
  `SYSTIMESTAMP` — `TB_MOTNJE.USTVARJEN` ([`disturbance_schema.sql:120`](../tools/ords/disturbance_schema.sql)),
  `TB_OBHODI.USTVARJEN` ([`walks_schema.sql:53`](../tools/ords/walks_schema.sql)),
  `TB_MOTNJE_FOTO.USTVARJEN` ([`disturbance_schema.sql:200`](../tools/ords/disturbance_schema.sql)) — and the
  two PUT handlers set `SPREMENJEN = SYSTIMESTAMP` ([`disturbance_endpoints.sql:579`](../tools/ords/disturbance_endpoints.sql),
  [`walks_endpoints.sql:427`](../tools/ords/walks_endpoints.sql)). `SYSTIMESTAMP` is the DB host's *zoned*
  local time; assigning it to a TZ-naive `TIMESTAMP` keeps the **local wall-clock digits**. The GET
  serializer (`TO_CHAR(SYS_EXTRACT_UTC(CAST(col AS TIMESTAMP WITH TIME ZONE)), '…"Z"')`) is **correct and
  identical** for every timestamp — proven by `observedAt`/`startedAt`/`endedAt` round-tripping fine (TB-13)
  — so the defect is the *stored digits*, not the serialization. Client-supplied columns land as UTC digits;
  only the `SYSTIMESTAMP`-stamped ones land local. (The serializer's `CAST … AS TIMESTAMP WITH TIME ZONE`
  assumes the ORDS session runs at UTC, which is precisely why the client-UTC columns are correct.)
- **Implemented (2026-06-22, DEPLOY-READY — NOT YET DEPLOYED; manual APEX SQL Workshop deploy by maintainer):**
  Fixed at the stored-value source so the data-at-rest is honest UTC (not a read-time patch). (1) **Schema
  defaults** → `SYS_EXTRACT_UTC(SYSTIMESTAMP)`: CREATE-table defaults updated + idempotent re-run-safe ALTER
  blocks appended — `disturbance_schema.sql` §8 (TB_MOTNJE + TB_MOTNJE_FOTO), `walks_schema.sql` §4
  (TB_OBHODI), matching the 2026-05-11 ALTER-block precedent. (2) **PUT handlers** → `SPREMENJEN =
  SYS_EXTRACT_UTC(SYSTIMESTAMP)` in both endpoint files (the sibling latent defect, fixed in the same pass).
  (3) **Existing rows**: new run-once, opt-in [`tools/ords/tb14_backfill_audit_ts_utc.sql`](../tools/ords/tb14_backfill_audit_ts_utc.sql)
  — `SYS_EXTRACT_UTC(FROM_TZ(col,'Europe/Ljubljana'))`, DST-aware (correct for both +1/+2), with read-only
  pre-flight + verify queries that double as an "already-applied?" guard (walks `createdAt`≈`endedAt`).
  The GET serializer is intentionally **unchanged** (storing UTC digits puts `createdAt` on the same basis
  as the already-correct client columns; surgical). **Deploy order** (low-write window): backfill → re-deploy
  the two schema files → re-deploy the two endpoint files; verify via the walks check + existing
  `test_walks.sh`/`test_disturbances.sh`. ARCHITECTURE §9.3 caveat + STATE `disturbance_schema`/`walks_schema`
  status updated. Possible future hardening (out of scope): switch the serializer's `CAST` to
  `FROM_TZ(col,'UTC')` to drop the session-TZ assumption entirely.
- **Shipped:** Deployed to ARSO prod via APEX SQL Workshop 2026-06-22 (maintainer-run), verified read-only the
  same day. Q1: all three `USTVARJEN` defaults now read `SYS_EXTRACT_UTC(SYSTIMESTAMP)` (forward fix live).
  Q2: the 10 most-recent walks show `createdAt − endedAt = 0` (0–1 s POST delay) — the exact inversion of the
  `+2.00 h` that diagnosed the bug, confirming the backfill landed. Disturbance side covered by the same
  default flip + identical `FROM_TZ` backfill transform. Source committed (PR pending). Spun off **TB-20**
  (auth-token audit timestamps, same root cause but latent + security-critical — deferred, not folded in).

### TB-15 · Export a disturbances + walks report for a chosen date range
`✨ Enhancement` · `P2` · `Blocked` (awaiting template) · Reporter: Matjaž · Updated: 2026-06-22
- **Problem / want:** Export a report covering both disturbances (motnje) and patrols (obhodi) for a
  selected calendar period, so wardens/management can produce periodic reports.
- **Blocked on:** Matjaž is sending a template (*predloga*) that defines the output — format
  (PDF / XLSX / …), fields, and layout. The format half can't be finalized until it arrives.
- **What we can scope now (template-independent):** Data is all client-side — `AppState.records`
  (`List<Disturbance>`) and `AppState.walks` (`List<Walk>`) ([`app_state.dart`](../lib/state/app_state.dart)),
  each carrying timestamps (`observedAt`; walk `startedAt`/`endedAt`) — so a date-range picker + filter is
  straightforward.
- **What the template decides:** output format + columns/sections; whether disturbance photos are embedded
  (heavier); per-walk detail depth (duration / track length / linked-motnje counts); grouping (by day /
  reporter / category).
- **Context / tooling gap:** No export/share/PDF/spreadsheet deps today (only `intl`, `path_provider`) and
  no existing report code — needs a new package chosen by the format: PDF → `pdf` + `printing`; tabular →
  `excel` or `csv`; plus `share_plus` (or `printing`) to share/save. Decide report **scope** — own records
  only vs the whole org (records/walks are pulled org-wide) — and ensure the period's data is fully synced
  before export (offline gaps). **Depends on TB-13** — report times must be local, or the report repeats the
  UTC error. Overlaps TB-6's date/reporter/category filtering (could share a filter predicate).
- **Discussion:** Await template, then pick format + tooling and split into (a) date-range data gather +
  (b) render/export.
- **Shipped:** —

### TB-16 · Preview a disturbance before submitting
`✨ Enhancement` · `P2` · `Todo` · Reporter: Matjaž · Updated: 2026-06-22
- **Problem / want:** Before a disturbance is saved, show a review of everything entered — photos, type
  (šifra), note (opomba), location, action taken (ukrep), and the rest — so the warden can catch mistakes
  before committing.
- **Context:** Entry form is [`form_screen.dart`](../lib/screens/form_screen.dart); submit is `_save()`
  ([:340](../lib/screens/form_screen.dart)) behind the "Shrani zapis" button
  ([:699](../lib/screens/form_screen.dart)), which builds the `Disturbance`, calls
  `AppState.addRecord(record)` ([:381](../lib/screens/form_screen.dart)) and pops. A preview is a confirm
  step inserted between the tap and `addRecord`: summarise the in-state fields (`_location`/`_accuracy`,
  `_date`/`_time`, `_types`, `_photos`, `_observers`, `_actionTaken`, `_legalBasis`, `_caseStatus`,
  proposed type) in a screen or bottom sheet with Back / Confirm. Self-contained client-side — no backend,
  no model change; [`detail_screen.dart`](../lib/screens/detail_screen.dart) already renders these fields
  and could be reused as the preview body.
- **Why valuable:** post-hoc editing isn't available yet (TB-2), so a pre-submit check is the main guard
  against a wrong/incomplete record. A confirm step also **mitigates TB-2's duplication** (the double-tap /
  retry that mints duplicate records) by gating the save behind an explicit confirm.
- **Discussion:** Decide presentation (full review screen vs bottom sheet) and whether it's always-on or
  opt-in. Show times in **local** time (depends on TB-13).
- **Shipped:** —

### TB-17 · Show the obhod (patrol) link in the records list
`✨ Enhancement` · `P3` (quick win) · `Todo` · Reporter: Matjaž · Updated: 2026-06-22
- **Problem / want:** In *Seznam zapisov* (the user's own disturbance list), also show which **obhod** a
  record belongs to, when the disturbance was captured during a patrol.
- **Context:** [`record_list_screen.dart`](../lib/screens/record_list_screen.dart) renders each record as a
  `ListTile` (title = type names, subtitle = `observedAt` date). The link already exists on the model —
  `Disturbance.obhodId` (`String?`, set when the motnja was logged during a walk, and synced). Resolve it to
  the walk via `state.walks` (`walk.id == record.obhodId`) and show a label — a small badge or a second
  subtitle line. Self-contained client-side; no backend or model change.
- **Discussion:** Decide the label when `walk.name` is null (common — walks are often unnamed): fall back to
  the walk's start date/time or a generic "Del obhoda". Optionally make the label tappable →
  `WalkDetailScreen` (nice-to-have). If it shows the walk date, use **local** time (TB-13).
- **Shipped:** —

### TB-18 · Filter map entries by year / reporter / category
`✨ Enhancement` · `P2` · `Todo` · Reporters: Tomaž, Rudi · Updated: 2026-06-22
- **Problem:** Beyond the on/off toggle (TB-6), wardens want to narrow what's on the map to quickly reach
  the entries they care about — not just declutter.
- **Want:** Filter historical entries by **year**, **reporter**, and **disturbance category**.
- **Context:** A filter UI (chip row / bottom sheet) + a predicate over `state.records` (and the legacy
  set) feeding the same map layers [`home_screen.dart`](../lib/screens/home_screen.dart) already builds.
  Larger than TB-6's toggle — needs the filter surface + state + applying the predicate to the markers.
  Reporter/category come from record fields (`createdBy`, `types`); year from `observedAt` (local — TB-13).
  Could share a date predicate with TB-15's report export.
- **Discussion:** Split from TB-6 on 2026-06-22. Decide filter UX (bottom sheet vs chip row) and whether
  filters compose (AND across year + reporter + category).
- **Shipped:** —

### TB-19 · Enlarge the tap target for disturbance markers on the map
`🐞 Bug` (usability) · `P2` · `Todo` · Reporter: maintainer · Updated: 2026-06-22
- **Problem:** Selecting a disturbance marker on the map is hard — the touch area is small, so it takes
  several attempts to hit one.
- **Context:** In `_buildMarkers` ([`home_screen.dart:622`](../lib/screens/home_screen.dart)) each record is a
  `Marker` whose `GestureDetector` child fills the marker box, so the **box size is the tap target**:
  disturbances **32×32** ([:651](../lib/screens/home_screen.dart)), legacy records **22×22**
  ([:629](../lib/screens/home_screen.dart)) — both under Material's 48 dp minimum, and smaller than the
  **44×44** the walk-detail map already uses ([`walk_detail_screen.dart:144`](../lib/screens/walk_detail_screen.dart)).
  The visible disc is only 18×18, wrapped in `Center` ([`basemap.dart:193`](../lib/widgets/basemap.dart),
  `RecordMarker`), so it's already a small dot inside a larger box. (Likely worsened by TB-7, which shrank the
  recent-entry discs.)
- **Want:** A bigger, easier tap target without enlarging the visible dot.
- **Fix shape:** Bump the `Marker` `width`/`height` to ~44–48 in `_buildMarkers` (disturbances + legacy).
  Because `RecordMarker`/`LegacyRecordMarker` is a `Center` around a fixed-size disc, the extra size becomes
  invisible tappable margin — the dot is unchanged, the hit area grows. Pure client change, no model/backend.
- **Discussion:** Caveat for dense areas — bigger hit boxes overlap more and flutter_map gives the tap to the
  top-most marker, so picking a *specific* one among overlapping points stays ambiguous; TB-6 (declutter
  toggle) / TB-18 (filter) address density. Pick a size that helps isolated markers without being over-grabby
  where points cluster.
- **Shipped:** —

### TB-20 · Auth-token audit timestamps stored local, mislabeled UTC (TB-14 sibling)
`🐞 Bug` (latent, audit-only) · `P3` · `Triage` (backend) · Reporter: Claude (found during TB-14, 2026-06-22) · Updated: 2026-06-22
- **Problem:** `TB_AUTH_TOKENS.CREATED_AT`/`EXPIRES_AT`/`LAST_USED_AT`/`REVOKED_AT` are stamped from
  `SYSTIMESTAMP` into TZ-naive `TIMESTAMP` columns ([`auth_token_schema.sql:44`](../tools/ords/auth_token_schema.sql);
  [`disturbance_auth_pkg.sql:157`](../tools/ords/disturbance_auth_pkg.sql)`-158`, `:296-297`, `:315`) — local
  wall-clock digits, the same root cause as TB-14.
- **Why it's NOT urgent (and not folded into TB-14):** These never cross the wire mislabeled. The client-facing
  `expiresAt` in the login response is computed *separately and correctly* with `SYS_EXTRACT_UTC(SYSTIMESTAMP)`
  ([`auth_login.sql:236`](../tools/ords/auth_login.sql)), so it's honest UTC. And the expiry gate
  (`expires_at < SYSTIMESTAMP`, [`disturbance_auth_pkg.sql:247`](../tools/ords/disturbance_auth_pkg.sql)/`:289`)
  compares two consistently-local values, so the 30-day sliding lifetime is correct; the server 401 is
  authoritative regardless. Net: an internal audit-readability wart (an operator querying `tb_auth_tokens` sees
  local times that look UTC), not a functional defect.
- **Caveat for the fix:** NOT a one-liner like TB-14. The stored values **and every comparison site**
  (`< SYSTIMESTAMP`) must move to UTC *together* — fixing only the stored side would shift expiry by the host
  offset and could expire tokens early/late. Coordinated change across the security-critical `pkg_tb_auth`
  + a backfill, then re-run the 7/7 token-lifecycle smoke test.
- **Discussion:** Decide whether audit-readability justifies touching the auth package, or whether a code
  comment ("stored local by design; expiry is offset-agnostic; wire `expiresAt` is UTC") suffices.
- **Shipped:** —

### TB-21 · Walk speed cap too low — drive-along walks get dropped
`✨ Enhancement` · `P1` · `Doing` (code complete + `flutter analyze` clean 2026-06-23; pending commit + release build) · Reporter: field testers (via maintainer) · Updated: 2026-06-23
- **Problem:** Wardens sometimes do a walk-around (obhod) by car, but the recorder's teleport filter rejected
  any segment implying > 8 m/s (≈29 km/h) as a bogus fix — so legitimate car-driven points were silently
  dropped (`reject: teleport` log) and the captured track came out sparse or broken.
- **Want:** Raise the ceiling above any realistic road speed so car-driven walks record fully, while the gate
  still catches genuine GPS teleports.
- **Context:** Single threshold in the FGS recorder isolate — `WalkTaskHandler._maxSpeedMps`
  ([`walk_task_handler.dart:43`](../lib/services/walk_task_handler.dart), applied at `:133`). The gate's real
  job is catching GPS hardware teleports (instantaneous jumps of hundreds of m/s), **not** enforcing a walking
  pace. Raised **8 → 36 m/s (≈130 km/h)**: covers every legal Slovenian road speed incl. highway, still far
  below a teleport. Raw points remain the write-once honest record; the render-time accuracy polish (TB-3,
  [`track_polish.dart`](../lib/services/track_polish.dart)) is untouched. No test exercises the FGS isolate.
  ARCHITECTURE §"Walk-tick filter" updated.
- **Discussion:** Ceiling chosen by maintainer (130 km/h) over 90 km/h (would clip highway segments) and
  180 km/h (looser teleport-only guard).
- **Shipped:** — (pending commit + the next closed-testing build, will bump from v1.3.1+12)

---

## Done

### TB-1 · Persistent login (don't ask for credentials every launch)
`✨ Enhancement` · `Done` · Reporters: Tomaž, Matjaž
- **Was:** App required username + password (same as NarcIS) on every launch; reporters noted
  it as time-consuming and low-risk to relax.
- **Shipped:** Bearer-token persistent login — token minted at login, stored in
  `flutter_secure_storage`, restored on cold start (30-day sliding expiry). `v1.2.0+7`
  (`880ebbe`), backend deployed + 7/7 smoke-tested against narcis.gov.si 2026-05-28.
  See ARCHITECTURE §9.1b / §12bis, OPERATIONS §8.

### TB-5 · Kolofon — LIFE Tršca funding attribution
`✨ Enhancement` · `Done` · Reporter: Tomaž
- **Was:** As a LIFE Tršca project deliverable, the app must show a funding colophon with the
  required statement and the three project logos.
- **Shipped:** `FundingFooter` renders a single composite logo strip
  (`assets/images/funding_logos.png`) at the bottom of the Profil page, plus the required
  sentence. `v1.2.1+8` → `v1.2.3+10` (`c62e55b`, `e8fdb15`, `ec37013`). The composite was
  authored manually after row-of-three layouts looked unbalanced (STATE.json `bundled_assets`).
  - Required statement: *Projekt LIFE TRSCA (št. 101114184 — LIFE22-NAT-SI-LIFE TRSCA)
    sofinancirata Evropska unija iz programa LIFE in Ministrstvo za naravne vire in prostor.*

### TB-7 · Shrink recent-entry dots to match old entries
`✨ Enhancement` · `Done` · Reporter: Tomaž
- **Was:** Red dots for recent disturbances were larger than the blue dots for old entries.
- **Shipped:** Recent-entry discs shrunk to the old-entry size; youngest rendered on top.
  `97b5421` ("Markers: shrink discs + render youngest on top").

### TB-11 · Color own walks distinctly from teammates' on the map
`✨ Enhancement` · `Done` · Maintainer-initiated
- **Was:** The home-map Obhodi layer drew every walk in the org — own and teammates' — in the
  same blueGrey, so a supervisor couldn't tell which tracks were their own.
- **Shipped:** Own walks now render orange (alpha 0.8, stroke 4) and draw on top; teammates' stay
  blueGrey (alpha 0.55, stroke 3) underneath; the active recording track is unchanged (green).
  Per-walk split via `state.isWalkAuthoredByCurrentUser` in `_buildPolylines`
  ([`home_screen.dart`](../lib/screens/home_screen.dart)) — no backend/sync/model change.
  ARCHITECTURE "Historical walks layer" note updated. `flutter analyze` clean. Committed (`73edf9a`);
  ships in **v1.3.0+11**, the closed-test build.

### TB-10 · "Območja s statusom" map overlay (5 sublayers)
`✨ Enhancement` · `Done` · Maintainer-initiated
- **Was:** The field map had no protected-area context. Wanted the `narcis-vibed` "Območja s statusom"
  layers — Natura 2000, zavarovana območja, EPO, naravne vrednote, jame — as toggleable overlays with
  tap → list → detail.
- **Shipped:** All five ZOS sublayers as server-rendered WMS tiles from the production NarcIS GeoServer
  (`narcis.gov.si/ows/ows`, `SI.NARCIS:ZOS_*`) + tap-to-identify (GetFeatureInfo), a per-sublayer layer
  picker (N2k default), and a list ⇄ detail sheet whose swatches mirror each layer's SLD — colour +
  shape (filled/outline areas, ZO circles, NV triangles, jame cave glyph), matched on
  `tip`/`ZO_VRSTA`/`NV_POMEN`/`NV_STATUS` + geometry. `obmocja_store.dart`, `obmocja_picker.dart`,
  `obmocje_sheet.dart`, `basemap.dart`, wired in `home_screen.dart`; `proj4dart` removed; suite 43/43.
  `d5a41b3` → `b139558` → `773e43f` → `477b7d2` → `3209a2b` (release `104784a`). Shipped in **v1.3.0+11**,
  rolled out live on the Play **Closed testing** track 2026-06-15. See ARCHITECTURE §10.2. Follow-ups
  (separate): on-map legend; tune point-layer (jame/NV/EPO) tap tolerance.
