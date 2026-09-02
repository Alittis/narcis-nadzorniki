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

### TB-2 · Delete disturbance entries from the phone
`🐞 Bug` · `P1` · `Done` (shipped v1.9.0+18, rolled out on the Play Closed testing track 2026-09-02; **the delete never reached the server on that build** — fixed in [TB-33](#tb-33--delete-never-reached-the-server--ords-400-on-every-bodyless-delete)) · Reporter: Matjaž · Updated: 2026-09-02
- **Scope narrowed 2026-09-02.** This item was "edit / delete". Delete is what the report actually
  needed — duplicates — and it is the clean half: `DELETE :id` sends no body, so none of the
  column-ownership problems arise. **Edit moved to [TB-32](#tb-32--edit-a-disturbance-from-the-phone),**
  which carries an ORDS change and cross-repo coordination. Splitting was a deliberate call, not a
  descoping: see TB-32 for what edit needs and why it is not a UI task.
- **Problem:** In the field, one disturbance was logged several times instead of once
  (reporter suspects weak signal or low battery). There is no way to correct it afterward.
- **Want:** Edit and delete entries from the profile → *Seznam zapisov* list.
- **Context:** Server PUT/DELETE `disturbances/:id` already exist and are smoke-tested
  (ARCHITECTURE §9.3); [`record_list_screen.dart`](../lib/screens/record_list_screen.dart)
  already lists the user's own records. Two distinct sub-tasks:
  1. **Root-cause the duplication.** POST is idempotent on the client UUID, so duplicates
     mean the client minted *multiple* records (multiple UUIDs) — likely a double-tap on
     save or a retry that re-generated the id. Reproduce before fixing.
  2. **Surface delete in the UI, and close the offline gap while doing it.** The old
     `deleteRecord` only reached Oracle when `isOnline && canSync`, and it applied the local
     removal *first* — see the Built note for why that was worse than it sounds.
- **Discussion — sub-task 1 has an answer (2026-09-02, found while building TB-31).** The client had
  **no in-flight guard on save**: `FilledButton.icon(onPressed: _save)` stayed enabled while
  `addRecord` awaited photo materialisation, the optimistic POST *and* the photo uploads — seconds on a
  weak link, which is exactly the "weak signal" condition Matjaž reported. A second tap re-entered
  `_save`, minted a second `_uuid.v4()` and filed a second record. That fits the evidence: POST is
  idempotent on the client UUID, so duplicates require the client to mint multiple ids.
  **Fixed in TB-31** (live in the field from v1.8.0+17, 2026-09-02) — the commit now happens in
  `DetailScreen._handleSave` behind a `_saving` flag with
  the button disabled for the whole await, regression-tested in
  [`preview_before_save_test.dart`](../test/preview_before_save_test.dart).
  ⚠️ **That did not close TB-2.** It removed the most likely *source* of new duplicates; it neither
  proves that was the only source (never reproduced on the reported device) nor gave anyone a way to
  clean up records already in `TB_MOTNJE`. This item is that cleanup path.
- **Discussion — RESOLVED 2026-09-02 (two calls by Alexis):** (1) **delete first, properly queued**,
  rather than edit+delete at once or an online-only version — an online-only delete would be useless in
  exactly the weak-signal situation the bug was reported from; (2) **records the back office has acted
  on are not deletable from the phone**, and the UI says why.
- **Built 2026-09-02** — client-only, **no ORDS/DB/schema change** (`DELETE :id` already existed and was
  smoke-tested, §9.3):
  - **`pendingDelete` on `Disturbance`** ([`disturbance.dart`](../lib/models/disturbance.dart)) — persisted,
    and defaulted `false` when absent so pre-TB-2 cached rows rehydrate.
  - **`deleteRecord` queues instead of applying** ([`app_state.dart`](../lib/state/app_state.dart)): mark
    `pendingDelete`, persist, then drain if online. Returns `true` only when the server confirmed and the
    row was purged, so the snackbar can say *"Zapis je izbrisan"* vs *"Zapis bo izbrisan ob naslednji
    sinhronizaciji"* truthfully.
  - **⚠️ The bug the old version actually had.** It removed the row *and deleted its photo directory*
    immediately, then fired DELETE with no retry. `_mergeRemoteIntoLocal` treats the server as
    authoritative for records known to both sides — so an offline delete **silently undid itself**: the
    next pull found a row the server still had and no local copy, and re-created it, photos and all. The
    naive "just add two buttons" version of this item would have shipped that. Three pieces fix it: the
    `records` getter hides `pendingDelete` rows from every read surface, the merge has an explicit
    `pendingDelete` branch, and the drain runs *before* the pull inside `syncAll`.
  - **A `pendingSync` row queued for delete is never POSTed** — on a flaky link the POST could land while
    the DELETE does not, leaving exactly the orphan the user asked to remove. Safe because
    `RemoteApi.deleteRecord` already accepts 404.
  - **`Disturbance.isLockedByReview`** — true once TB-26's `reviewedBy`/`reviewedAt` are set (web-only
    fields) or `caseStatus` has moved off `'Odprto'`. `RecordActionsMenu` explains rather than deletes;
    the menu item stays *enabled* on purpose, because a greyed-out row tells the warden nothing.
  - Tests: [`record_delete_test.dart`](../test/record_delete_test.dart) — 9 covering the model, the
    lock rule, the offline queue, the confirmed purge, the create-skip, and the row menu. The
    load-bearing one is *"a failed delete stays queued and the pull does NOT resurrect it"*. It needed a
    booted-`AppState` harness (fake local/walks store, auth, connectivity, photo storage + `MockClient`)
    which did not exist in this repo before — **reusable for TB-32.** ⚠️ `pumpEventQueue()` **hangs**
    inside `testWidgets`, where the binding controls time; the harness only drains when online.
    Full suite **142/142**, analyze at the documented 10 pre-existing info lints.
  - **⚠️ Known edge in the lock rule.** `isLockedByReview` keys partly off `caseStatus != 'Odprto'`,
    and the phone's create form still has a `caseStatus` dropdown — so a warden who picks a non-default
    status *at creation* locks their own record against deletion immediately, with no reviewer involved.
    Accepted for now: it fails safe (refuses a delete rather than allowing a bad one) and it is rare,
    since the dropdown defaults to `'Odprto'`. The real fix is [TB-32](#tb-32--edit-a-disturbance-from-the-phone)'s
    open question — if status is web-owned, that dropdown should not be on the phone at all, and this
    edge disappears with it.
  - **Not verified on a device.** Analyzer + tests only.
- **Built into v1.9.0+18** (2026-09-02, archived `~/Releases/terenska-beleznica-1.9.0+18.aab`, signed
  with the upload key). Build exit 0; analyze at the documented 10 pre-existing info lints; suite
  **142/142**; signer cert SHA-256 matches `upload_cert_sha256` with Owner `CN=Terenska beleznica`;
  versionName 1.9.0 in the AAB manifest (1.8.0 absent), versionCode 18 from `packaged_manifests`;
  `com.example` and `ACCESS_BACKGROUND_LOCATION` absent; all four `hardware.camera*`/`location*`
  features present. **Needs no server change** — `DELETE :id` already existed.
- **Shipped:** v1.9.0+18, **rolled out on the Play Closed testing track 2026-09-02**.
- **⚠️ The queue was right; the wire call was not.** On the rolled-out build every `DELETE` failed with
  an ORDS 400, so records vanished from the phone and stayed on the server — see
  [TB-33](#tb-33--delete-never-reached-the-server--ords-400-on-every-bodyless-delete). Worth recording
  what that says about this item's own testing: the queue mechanics were tested thoroughly against a
  `MockClient`, which answers whatever it is told to, so **every test passed while the real request
  shape was rejected by ORDS.** The mechanism was verified; the contract with the server was not.
  Ironically the queue is why nothing was lost — the rows survived and drained once the header was fixed.
  **And it was worse than that:** the harness's mock GET body was latin-1 encoded, so every pull in every
  one of these tests silently never ran — meaning the *"the pull does NOT resurrect it"* test named above
  as load-bearing was passing without executing the merge at all. Found and fixed in
  [TB-35](#tb-35--a-confirmed-delete-still-showed-as-unsynced--and-the-test-that-should-have-caught-it-was-vacuous),
  where both guards were re-verified by removal.
- **Follow-up shipped alongside the fix:** [TB-34](#tb-34--delete-from-the-record-details-view-not-just-the-list-row)
  adds the same delete action to the details view, which is where the reporter points out most delete
  decisions are actually made.

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

### TB-6 · Filter the Motnje layer — age / author / observed-date window
`✨ Enhancement` · `P2` · `Done` (shipped v1.5.0+14; rolled out on the Play Closed testing track 2026-06-24) · Reporters: Tomaž, Rudi · Updated: 2026-06-24
- **Problem:** In places there are so many points they obscure the map and hurt readability; wardens want
  to narrow the Motnje layer to the entries they care about.
- **Want (clarified 2026-06-24, maintainer):** Not a plain on/off — a **filter on the Motnje layer**,
  opened like the Območja picker, choosing which disturbance markers show by **(1) age/colour** (the
  red/orange/blue buckets), **(2) author**, and **(3) a two-sided date-range slider**. This **supersedes the
  original "visibility toggle" framing** and **merges most of TB-18** (its year→date and reporter→author
  dimensions); only TB-18's **disturbance-type/category** dimension is left out of this pass.
- **Note on "historical":** the 703 Notranjski legacy records were migrated into `TB_MOTNJE` on 2026-05-22
  (the old "Zgodovina" chip removed then), so they now render as ordinary aged-🔵 Motnje markers — i.e. the
  "historical clutter" the reporters meant. Hiding the 🔵 *Starejše* bucket declutters them directly. (The
  `showLegacy`/`legacyRecords` layer is now vestigial dead code — separate cleanup, not part of this.)
- **Implemented (2026-06-24, in source — pending commit + release build):** New pure helper
  [`disturbance_filter.dart`](../lib/data/disturbance_filter.dart) — `AgeBucket`/`ageBucketOf` (≤31 d recent,
  ≤365 d mid, older old), `MotnjeFilter` (age buckets ∩ authors ∩ inclusive observed-date window,
  AND-composed; `isActive`, `matches`) + `authorsIn`/`observedSpan`. The marker colour
  ([`basemap.dart`](../lib/widgets/basemap.dart) `recordMarkerColorForAge`) now derives from the **same**
  `ageBucketOf`, so the legend and the filter can't drift. New
  [`motnje_filter_sheet.dart`](../lib/widgets/motnje_filter_sheet.dart) `showMotnjeFilterSheet` — a bottom
  sheet (mirrors the Območja picker; live-pushes each change so the map redraws behind it) with age
  checkboxes (colour-dotted), single-select author rows (Vsi / "(jaz)" / colleague — single-select sidesteps
  the empty=all-vs-none ambiguity; the model is a `Set` so it can grow to multi later), a month-granularity
  `RangeSlider` (emits on drag-end), a live "Prikazanih: N od M" count, and Ponastavi. Wired into
  [`home_screen.dart`](../lib/screens/home_screen.dart): a **separate "Filter" chip** (funnel icon,
  `selected` when `isActive`, enabled only while Motnje is shown — the Motnje chip keeps its one-tap on/off,
  maintainer's pick) opens the sheet; `_buildMarkers` skips records failing `_motnjeFilter.matches`.
  Widget-local, not persisted (matches the other toggles); no model/backend/deps change. 16 unit tests
  ([`disturbance_filter_test.dart`](../test/disturbance_filter_test.dart)) + 4 widget tests
  ([`motnje_filter_sheet_test.dart`](../test/motnje_filter_sheet_test.dart)); `flutter analyze` clean (10
  pre-existing info lints, no new); full suite **91/91** (was 71). ARCHITECTURE §10.3 added.
- **Update (2026-06-24):** the disturbance-**category** dimension (the last TB-18 piece) is now also built
  into the sheet — multi-select over the groups present in the data, OR-within-dimension — closing TB-18.
  The date-slider/age-bucket temporal overlap is handled by AND + the live count (both default to "all" =
  no-op).
- **UX revision (2026-06-24, maintainer):** dropped the separate "Filter" pill — the **Motnje chip now opens
  the sheet directly** (same chip→sheet pattern as Območja). The layer show/hide moved into the sheet as a
  **Prikaži na zemljevidu** master switch at the top; the chip stays highlighted while the layer is shown.
  `_TopChrome` lost the `filterActive`/`onFilterTap` params (`onMotnjeToggle` → `onMotnjeTap`); the sheet
  gained `showMotnje`/`onShowChanged` + a master-switch widget test (suite **98/98**).
- **Shipped:** Built into **v1.5.0+14** (2026-06-24, archived `~/Releases/terenska-beleznica-1.5.0+14.aab`,
  signed with the upload key); rolled out on the Play Closed testing track 2026-06-24.

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
`✨ Enhancement` · `P2` · `Done` (shipped v1.4.0+13; rolled out on the Play Closed testing track, confirmed working 2026-06-24) · Reporter: Matjaž · Updated: 2026-06-24
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
- **Decisions (2026-06-23, maintainer):** **(1) layout** — the search box is an *addition above* the
  existing coloured group cards, not a replacement: an empty box keeps the grouped/collapsible browse
  view unchanged; typing swaps to a flat results list (each row labelled with its group name, since
  type codes restart per group). **(2) match fields** — type name **+ group name**, accent- and
  case-insensitive; a group-name match pulls in all of that group's types (so "kopal" surfaces the
  whole Kopalci group). Note matching was *not* included. Also asked: make the **Končaj** button more
  prominent.
- **Implemented (2026-06-23, in source — pending commit + release build):** New pure helper
  [`disturbance_type_search.dart`](../lib/data/disturbance_type_search.dart) — `foldForSearch` (lower-case
  + strip č/ć/š/ž/đ) and `searchDisturbanceTypes` (returns `(group, type)` matches in codebook order,
  empty query → no matches). Wired into [`type_selection_screen.dart`](../lib/screens/type_selection_screen.dart):
  a persistent search `TextField` (search icon + clear button) above the list; empty query → the existing
  grouped `ExpansionTile` browse view, non-empty → a flat `CheckboxListTile` list (title `'code. name'`,
  group name as a colour-coded subtitle) or a "Ni zadetkov" message; the shared `_selected` map preserves
  selections across browse↔search and across queries. `Končaj` promoted from a flat `TextButton` to an
  AppBar `FilledButton.icon` showing the live selection count (`Končaj (N)`). Selection key/builder
  factored into `_selectionKey`/`_selectionFor` shared by both views (no model/backend change). 9 unit
  tests ([`disturbance_type_search_test.dart`](../test/disturbance_type_search_test.dart)) + 4 widget tests
  ([`type_selection_screen_test.dart`](../test/type_selection_screen_test.dart), browse↔search swap, no-match
  message, count badge); `flutter analyze` clean (no new issues), full suite **71/71** (was 58).
- **Shipped:** Built into **v1.4.0+13** (2026-06-23, archived `~/Releases/terenska-beleznica-1.4.0+13.aab`,
  signed with the upload key); committed `9f461a7`. Rolled out on the Play Closed testing track 2026-06-24 (confirmed installing + working).

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
`✨ Enhancement` · `P3` (quick win) · `Done` (shipped v1.7.0+16; rolled out on the Play Closed testing track 2026-08-31) · Reporter: Matjaž · Updated: 2026-08-31
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
- **Decision (maintainer, 2026-08-31):** walk **name with a date fallback**, and **tappable**.
- **Done (2026-08-31, in source; release pending):** `ObhodLink`
  ([`record_list_screen.dart`](../lib/screens/record_list_screen.dart)) as the row's **second** subtitle
  line (`isThreeLine`), under the date + status line TB-30 built. Walking icon, the label in the primary
  colour and underlined, tapping it pushes `WalkDetailScreen`.
- **The fallback logic already existed, so it was extracted rather than copied.** Seznam obhodov had
  `walk.name?.isNotEmpty == true ? name : startedAt` inline; that is now `walkLabel(walk, fmt)` in
  [`walk.dart`](../lib/models/walk.dart) and **both** screens call it, so they cannot drift into naming
  the same walk differently. Local time, per TB-13.
- **The link can be set while the walk is unresolvable, and that is a real case, not defensive padding.**
  A disturbance logged during an active walk carries `obhodId` before that walk has ever reached the
  server, and a fresh install pulls records and walks independently. When the lookup misses, the row
  shows a muted, **non-tappable** *"Del obhoda"* — the tap would otherwise dead-end on
  *"Obhod ni najden."*.
- **Tests:** in `test/record_list_status_test.dart` — named walk, unnamed → local-time fallback, empty
  name treated as unnamed, unresolvable → non-tappable *Del obhoda*, and a real **navigation** assertion
  (route pushed + `WalkDetailScreen` on screen) rather than merely "an InkWell exists". Suite **125/125**.
- **Shipped:** **v1.7.0+16**, archived `~/Releases/terenska-beleznica-1.7.0+16.aab` (signed with the upload
  key); **rolled out on the Play Closed testing track 2026-08-31**.

### TB-18 · Filter map entries by year / reporter / category
`✨ Enhancement` · `P2` · `Done` (shipped v1.5.0+14; rolled out on the Play Closed testing track 2026-06-24; delivered via TB-6's filter) · Reporters: Tomaž, Rudi · Updated: 2026-06-24
- **Problem:** Beyond the on/off toggle (TB-6), wardens want to narrow what's on the map to quickly reach
  the entries they care about — not just declutter.
- **Want:** Filter historical entries by **year**, **reporter**, and **disturbance category**.
- **Implemented (2026-06-24, in source — pending commit + release build):** All three dimensions are now
  delivered by TB-6's Motnje filter ([`motnje_filter_sheet.dart`](../lib/widgets/motnje_filter_sheet.dart) /
  [`disturbance_filter.dart`](../lib/data/disturbance_filter.dart)): **year** = the date-range slider,
  **reporter** = author single-select, **category** = a multi-select over the disturbance groups present in
  the data (`MotnjeFilter.groups` matched against `record.types[].groupCode`; `groupsIn` derives the option
  list so only present categories show; OR-within-dimension). Filtered at the **group** granularity, not the
  172 individual types — group is the useful filter granularity; per-type pick is the TB-12 search flow.
  5 unit tests (category + `groupsIn`) + 1 widget test added; full suite **97/97**; `flutter analyze` clean.
  ARCHITECTURE §10.3 updated.
- **Context:** A filter UI (chip row / bottom sheet) + a predicate over `state.records` (and the legacy
  set) feeding the same map layers [`home_screen.dart`](../lib/screens/home_screen.dart) already builds.
  Larger than TB-6's toggle — needs the filter surface + state + applying the predicate to the markers.
  Reporter/category come from record fields (`createdBy`, `types`); year from `observedAt` (local — TB-13).
  Could share a date predicate with TB-15's report export.
- **Discussion:** Split from TB-6 on 2026-06-22; **re-merged 2026-06-24** — TB-6 now owns the filter UI
  (bottom sheet, AND-composed) and this item is scoped down to the type/category dimension.
- **Shipped:** Built into **v1.5.0+14** (2026-06-24, archived `~/Releases/terenska-beleznica-1.5.0+14.aab`,
  signed with the upload key); rolled out on the Play Closed testing track 2026-06-24 — delivered via TB-6's filter.

### TB-19 · Enlarge the tap target for disturbance markers on the map
`🐞 Bug` (usability) · `P2` · `Done` (shipped v1.5.0+14; rolled out on the Play Closed testing track 2026-06-24) · Reporter: maintainer · Updated: 2026-06-24
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
- **Implemented (2026-06-24, in source — pending commit + release build):** Both home-map record-marker
  hit-boxes grown to a shared, documented constant `kRecordMarkerTapDiameter = 44`
  ([`basemap.dart`](../lib/widgets/basemap.dart)) — disturbances **32→44**, legacy **22→44** in `_buildMarkers`
  ([`home_screen.dart`](../lib/screens/home_screen.dart)). Because `RecordMarker`/`LegacyRecordMarker` `Center`
  a fixed ~18 px / ~11 px disc, the extra box is invisible tappable margin: the visible dots are **unchanged**,
  the hit area grows. **44** matches the walk-detail map ([`walk_detail_screen.dart:151`](../lib/screens/walk_detail_screen.dart))
  and sits just under Material's 48 dp minimum — chosen over 48 to limit how much overlapping hit-boxes steal
  each other's taps in dense clusters (the density caveat above; declutter/filter stay deferred to TB-6/TB-18).
  Disturbances are added after legacy in `_buildMarkers`, so they draw on top and still win the tap in an
  overlap (live record over historical). Pure client UI change — no model/backend/deps, no ARCHITECTURE/STATE
  impact (walk-detail's literal `44` left untouched; value now matches). `flutter analyze` clean (10
  pre-existing info lints, no new); full suite **71/71**. No automated test added: the box size is a
  flutter_map `Marker` property set inside the private `_buildMarkers` (depends on widget state + a live map),
  with no pure-function seam — a HomeScreen widget test would need network tiles for marginal value (same call
  as TB-13's display-only fix).
- **Shipped:** Built into **v1.5.0+14** (2026-06-24, archived `~/Releases/terenska-beleznica-1.5.0+14.aab`,
  signed with the upload key); rolled out on the Play Closed testing track 2026-06-24.

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
`✨ Enhancement` · `P1` · `Done` (shipped v1.4.0+13; rolled out on the Play Closed testing track, confirmed working 2026-06-24) · Reporter: field testers (via maintainer) · Updated: 2026-06-24
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
- **Shipped:** Built into **v1.4.0+13** (2026-06-23, archived `~/Releases/terenska-beleznica-1.4.0+13.aab`,
  signed with the upload key); committed `9a9fee3`. Rolled out on the Play Closed testing track 2026-06-24 (confirmed installing + working).

### TB-22 · Walk tracks draw straight "spike" lines across driven / dropped stretches
`🐞 Bug` · `P1` · `Done` (shipped v1.4.0+13; rolled out on the Play Closed testing track, confirmed working 2026-06-24) · Reporter: field testers (via maintainer, screenshot) · Updated: 2026-06-24
- **Problem:** On existing walks where the warden walked *and* drove, the track shows long dead-straight lines
  shooting across the map (Cerknica screenshot, 2026-06-23). Each walk was drawn as a **single continuous
  `Polyline`** through every stored point, so any gap between consecutive points renders as a straight bridge.
  The gaps came from the old 8 m/s capture filter rejecting every driving fix (TB-21) and from GPS dropouts —
  the bridged ends sit hundreds of metres to kilometres apart.
- **Want:** Stop drawing the bridge lines. Existing walks can't be repaired at the source (raw points are
  write-once on the server and the rejected fixes were never stored), so the remedy is render-time.
- **Context:** Added `polishTrackSegments` to [`track_polish.dart`](../lib/services/track_polish.dart) —
  accuracy-filters, then **splits into separate polylines wherever two consecutive kept fixes jump > 200 m**
  (`kTrackGapSplitMeters`), then smooths each segment. Both render sites draw one `Polyline` per segment:
  [`walk_detail_screen.dart`](../lib/screens/walk_detail_screen.dart),
  [`home_screen.dart`](../lib/screens/home_screen.dart) `_buildPolylines` (teammate + own + active). Threshold
  is **distance-based, not time-based**: a stationary stop emits no fixes (`distanceFilter` 5 m) but its
  bracketing points are metres apart, so it stays one segment; a real drive samples at ~36 m steps even at
  130 km/h, well under 200 m. The flat `polishTrack` is kept as a no-split wrapper for the existing tests.
  Fixes both existing and future walks; with TB-21 also raising the capture cap, future walks capture the
  driving fixes and follow the road instead of leaving a gap. 6 new unit tests
  ([`track_polish_test.dart`](../test/track_polish_test.dart); full suite 58/58). Raw points + the TB-3
  accuracy/smoothing pass unchanged. ARCHITECTURE §"render-time polish" updated.
- **Discussion:** Chose gap-split with **no connector drawn** (honest holes) over a dashed bridge or
  walk-vs-drive styling (maintainer, 2026-06-23). Styling driven segments distinctly is a possible follow-up
  once field walks with captured driving exist.
- **Shipped:** Built into **v1.4.0+13** (2026-06-23, archived `~/Releases/terenska-beleznica-1.4.0+13.aab`,
  signed with the upload key); committed `d5ff149`. Rolled out on the Play Closed testing track 2026-06-24 (confirmed installing + working).

### TB-23 · Remove the vestigial `showLegacy` legacy-overlay layer (dead code)
`🔧 Chore` · `P3` · `Triage` · Reporter: Claude (found during TB-6, 2026-06-24)
- **Problem:** The bundled-legacy overlay is **dead code**. The "Zgodovina" chip was removed 2026-05-22
  (commit `1430a5a`) when its 703 records were migrated into `TB_MOTNJE`, and the comment in
  [`home_screen.dart`](../lib/screens/home_screen.dart) flagged full removal as a follow-up. `showLegacy`
  defaults `false` and **no UI enables it**, so the layer never renders; the `showLegacy`/`onLegacyToggle`
  params are still plumbed through `_TopChrome` but unused.
- **Want:** Remove the layer end-to-end — `AppState._showLegacy`/`showLegacy`/`setShowLegacy`, the
  `_TopChrome` `showLegacy`/`onLegacyToggle` params + wiring, the legacy branch in `_buildMarkers`,
  `LegacyRecordMarker` ([`basemap.dart`](../lib/widgets/basemap.dart)),
  [`legacy_detail_screen.dart`](../lib/screens/legacy_detail_screen.dart),
  [`legacy_records.dart`](../lib/data/legacy_records.dart) /
  [`legacy_disturbance.dart`](../lib/models/legacy_disturbance.dart), and the bundled
  `assets/legacy/notranjski_park_2025.json` (drop from `pubspec.yaml`) — trimming ~408 KB.
- **Context:** Surfaced while building TB-6 (the age filter now declutters the migrated, aged-🔵 records the
  legacy layer used to show). ARCHITECTURE §10.3/§11 note the vestigial status. Pure client deletion — no
  backend/DB change.
- **Discussion:** **Verify the 703 legacy records are all present in `TB_MOTNJE`** for the relevant org(s)
  before dropping the asset; if any are missing, that's a data-migration gap to close first.
- **Shipped:** —

### TB-24 · Pre-upload AAB check misses the signer certificate
`🔧 Chore` · `P2` · `Done` · Updated: 2026-08-06
- **Problem:** `DEPLOYMENT.md` §3.2 sanity-checked the AAB only with `unzip` + `strings` over the
  binary `base/manifest/AndroidManifest.xml` — applicationId, absent permissions, the four
  `required="false"` hardware features. That says nothing about **who signed it**. Release signing
  reads its passwords from the gitignored `android/key.properties` (§3.1), and if that file is
  missing the release build does not fail: it falls back to debug signing and yields an AAB that
  builds clean and is rejected on upload. Nothing in the documented check would catch it.
- **Want:** The signer verification in §3.2, plus an honest note on what the AAB genuinely cannot
  confirm, so a future release does not record a check it never performed.
- **Context:** `keytool -printcert -jarfile <aab>` prints Owner and the SHA-256 to compare against
  `android_release.upload_cert_sha256` in `STATE.json`. Verified 2026-08-06 against the archived
  `~/Releases/terenska-beleznica-1.5.0+14.aab`: `25:F1:C4:…:E6:A2`, matching `STATE.json` exactly.
  Also settled empirically, because both directions were previously assumed wrong: `versionName`
  *is* readable from the AAB (the binary string pool is **UTF-8**, so plain `strings` finds
  `1.5.0`; macOS `strings` has no `-e` flag and needs none), while **`versionCode` is not** — it is
  an integer attribute, not a pooled string, and `apkanalyzer manifest print` refuses an `.aab`
  while `bundletool` is absent on this workstation. The build number comes from the plain-XML
  merged manifest under `build/app/intermediates/packaged_manifests/release/`, which survives
  until `flutter clean` (the June 1.5.0+14 copies were still on disk and carried
  `android:versionCode="14"`). Note the path is `build/app/…`, not `android/app/build/…`, because
  `android/build.gradle.kts` redirects the Gradle build directory to the repo root.
- **Discussion:** —
- **Shipped:** Docs only, no app change — `DEPLOYMENT.md` §3.2. The same verified procedure is
  carried by the global `flutter-release` skill (`~/.claude/skills/flutter-release/SKILL.md` §3),
  which was corrected in the same pass: it had the merged-manifest path as `android/app/build/…`.

### TB-28 · Login says "wrong credentials" when the real problem is a missing TERENSKA-BELEZNICA authorization
`✨ Enhancement` · `P1` · `Todo` · Maintainer-initiated · Updated: 2026-08-29

- **Problem:** Registration in NarcIS is **not enough** to use Terenska beležnica. The account
  must additionally hold the `TERENSKA-BELEZNICA` function authorization, granted by an
  administrator. Nothing in the app says so. A registered user who types their **correct**
  password but lacks the function gets HTTP 401 with
  `{"authenticated":false,"message":"Neveljavni podatki za prijavo."}` — **byte-identical** to
  what a typo'd password produces ([`auth_login.sql:216`](../tools/ords/auth_login.sql) exits at
  `has_function_false`, and the single message is written unconditionally at line 301). The client
  renders that string verbatim ([`auth_service.dart:222`](../lib/services/auth_service.dart) →
  [`login_screen.dart:45`](../lib/screens/login_screen.dart) → the red banner), so the only
  conclusion available to the user is *"I mistyped my password"*. They retype it, fail again, and
  the actual remedy — **ask your organisation's administrator to assign you the function** — is
  reachable nowhere in the app.
- **Want:** The user is told, at the moment it happens, that their account is valid but not yet
  authorized for this app, and who to contact.
- **⚠️ The single message is DELIBERATE, not an oversight — do not "fix" it by differentiating
  every branch.** *"Server logic (single 401 message for all failure modes — no enumeration)"*
  ([`auth_login.sql:24`](../tools/ords/auth_login.sql)), restated in ARCHITECTURE §9.1 (line 66)
  and OPERATIONS §7 (*"no enumeration leak between 'no creds', 'bad password', 'not authorized'"*).
  Steps 1–3 must keep the generic message.
- **Why this one branch can nevertheless be split safely.** The function check is **step 4**, and
  it runs only *after* `pkg_narcis_uporabniki.preveri_geslo` returned true — the caller has already
  proven they know the password for that account. Telling **them** "this account is not authorized
  for Terenska beležnica" discloses nothing that an attacker without the password could reach; the
  properties worth protecting (*does this email exist?*, *is this password right?*) are untouched
  as long as only the `has_function_false` branch gets its own message. State this in the change
  itself, because three separate documents say "no enumeration" and a future reader will otherwise
  read the split as a regression.
- **Two halves — the cheap one is client-only and can ship first:**
  1. **Static hint on the login screen (no backend change, no ORDS re-publish).** One line under
     the error banner in [`login_screen.dart`](../lib/screens/login_screen.dart), shown on any
     failed online login: registration in NarcIS is not sufficient, the `TERENSKA-BELEZNICA`
     right is needed, here is who grants it. Imprecise — it also shows to someone who genuinely
     mistyped — but it costs one Flutter build and removes the dead end.
  2. **A distinct server message (needs an ORDS re-publish).** Give the `has_function_false` exit
     its own `message` (and ideally a stable machine-readable `reason`, e.g. `"not_authorized"`, so
     the client can style it as guidance rather than as an error) while every earlier step keeps
     `Neveljavni podatki za prijavo.`. The client already passes `body['message']` straight
     through, so half 2 improves the text with **no client release** — but a `reason` key would
     need one.
- **Decide who the user should be told to contact — this is the open question, and the repo
  currently answers it two different ways.** Both closed-test invite templates in
  `PLAY_CLOSED_TEST.md` (§ Slovenian ~line 517, English ~line 577) say to write to
  `admin@alittis.com`, i.e. the *app publisher*, who arranges the right. That is correct **for the
  closed test**, where Alittis provisions testers by hand. At production scale the addressee is the
  **organisation's own administrator** (ARSO / the relevant park; the store listing gives
  `narcis.arso@gov.si` as the field-data controller). Whatever wording lands in the app must name
  whichever is true at ship time — and if that is the org admin, **the two invite templates
  contradict it and must be updated in the same pass.**
- **The revocation case gets the same benefit.** A user whose function is *withdrawn* keeps working
  offline until the 14-day window lapses (OPERATIONS §9) and then meets this identical, misleading
  401. Wording should cover "not assigned yet" and "no longer assigned" without promising to
  distinguish them.
- **Not affected:** the offline branches in `AuthService._tryOffline` have their own distinct
  messages, and first-time login is always online (OPERATIONS §9), so an unauthorized user always
  reaches the server path. Only the online 401 needs the hint.
- **Today's only way to tell the two apart is operator-side and expiring:** the login handler logs
  `step_reached = 'has_function_false'` to `narcis_auth_debug`, so someone with DB access can
  diagnose a specific report ([`diagnose_auth.sql`](../tools/ords/diagnose_auth.sql) STEP 3b does
  it per user). That instrumentation is **scheduled for removal** (ARCHITECTURE §8 cleanup
  checklist, step 2/4) — if it is dropped before this ships, the last remaining way to distinguish
  the two failures disappears with it.
- **Discussion:** Contact addressee, per the bullet above — publisher (`admin@alittis.com`, today's
  closed-test answer) vs. the organisation's administrator (the production answer). Half 1 cannot
  ship until this is settled, since the whole point is naming someone.
- **Shipped:** —

### TB-29 · Retire age colouring end to end — the walk map, and the Starost filter with it
`🔧 Chore` · `P2` · `Done` (shipped v1.7.0+16; rolled out on the Play Closed testing track 2026-08-31) · Reporter: maintainer (on the v1.6.0+15 rollout) · Updated: 2026-08-31

- **Problem, as reported on the rolled-out build:** the Motnje filter sheet showed **two colour legends at
  once** — Starost (red/orange/blue) and the new Status obravnave (amber/blue/green/gray) — with only one
  of them meaning anything on the map. Investigating that surfaced a second, worse defect: the
  **walk-detail map had been left colouring by age**, so the same disturbance dot was encoded two
  different ways depending on which screen you opened it from.
- **Decision (maintainer, 2026-08-31): remove age colouring and the Starost filter entirely**, rather than
  keeping the filter and de-colouring its swatches. The reasoning that decided it: **Obdobje already
  filters the same axis, and better** — a day-granularity range over the records' real distribution, with
  a histogram — so three fixed buckets were the weaker of two overlapping controls, kept only because they
  used to double as the map legend. That justification died with TB-27.
- **Done (2026-08-31, in source; release pending):**
  - [`walk_detail_screen.dart`](../lib/screens/walk_detail_screen.dart) now uses
    `recordMarkerColorForStatus`, so both maps agree.
  - Removed: `AgeBucket`, `allAgeBuckets`, `ageBucketOf`, `MotnjeFilter.ageBuckets`,
    `recordMarkerColorForAge`, the sheet's `_buckets`/`_bucketRow`/`_toggleBucket` and its whole **Starost**
    section. `MotnjeFilter.matches` also lost its now-unused injectable `now:` clock, which existed only to
    make `ageBucketOf` testable.
  - **`_ObravnavaCard`** on the detail screen (see TB-26) — the same pass, since both defects were "TB-26/27
    shipped, but the user cannot read it".
  - Corrected two ARCHITECTURE claims this work falsified, one of which was **wrong when written**:
    §10.3 said `recordMarkerColorForAge` was the Starost swatch source, but the sheet hardcoded
    `Colors.red/orange/blue` and never called it; and the legacy-record note still credited the age filter
    with decluttering the 703 migrated records.
  - **Tests:** suite **114/114** (six age-specific tests deleted, three `_ObravnavaCard` tests added);
    `flutter analyze` at the documented 10 pre-existing info lints.
- **Discussion:** TB-6/TB-18 shipped Starost on Tomaž's and Rudi's request, so this removes something two
  people asked for. Flagged before doing it; the maintainer's call was that Obdobje covers the need. If
  field feedback disagrees, the cheapest restoration is a Starost section that filters without pretending
  to be a legend.
- **Shipped:** **v1.7.0+16**, archived `~/Releases/terenska-beleznica-1.7.0+16.aab` (signed with the upload
  key); **rolled out on the Play Closed testing track 2026-08-31**.

### TB-30 · Show the case status in Seznam zapisov
`✨ Enhancement` · `P3` · `Done` (shipped v1.7.0+16; rolled out on the Play Closed testing track 2026-08-31) · Reporter: maintainer · Updated: 2026-08-31

- **Want:** the record list should show each record's *status obravnave* after the observed date,
  in colour — today the subtitle is the date alone, so a warden must open every record to learn
  where it stands.
- **Done (2026-08-31, in source; release pending):** the subtitle is now `RecordStatusLine`
  ([`record_list_screen.dart`](../lib/screens/record_list_screen.dart)) — date, then a colour dot
  from `recordMarkerColorForStatus` **plus the status text**.
- **Why dot + label rather than a bare coloured dot.** Two reasons, both learned the hard way this
  week. The tile's `leading` icon already speaks in colour (green = synced, orange = pending sync),
  so an unlabelled dot beside it would read as a second sync indicator; and an unlabelled colour is
  exactly what made TB-26's first cut unreadable. The dot shares `recordMarkerColorForStatus` with
  both maps, the detail card and the filter sheet, so one status is one colour everywhere in the app.
- **A real layout bug the tests caught, not a hypothetical.** As a `Row`, *"Predano drugi službi"*
  after a full `dd.MM.yyyy HH:mm` timestamp **overflowed a 320 dp screen by 85 px**. A `Row` can only
  resolve that by ellipsizing, which would eat either the date or the status — both of which are the
  point. It is a `Wrap` now, so the status drops to a second line and nothing is lost, with a
  `Flexible`+ellipsis inside the status chunk as a last resort for large text scales.
- **Tests:** `test/record_list_status_test.dart` — labelling, the shared palette across all four
  statuses, the unknown-status gray fallback, and no-overflow at **320 / 360 / 411 dp** (the widths
  that caught the bug). Suite **119/119**.
- **Note:** `RecordStatusLine` is public so it can be widget-tested directly. `AppState.records` is
  unmodifiable with no test seam, and adding a test-only seam to production state for one row of UI
  was the worse trade.
- **Adjacent, still open:** TB-17 wants the *obhod* link on these same rows.
- **Shipped:** **v1.7.0+16**, archived `~/Releases/terenska-beleznica-1.7.0+16.aab` (signed with the upload
  key); **rolled out on the Play Closed testing track 2026-08-31**.

### TB-26 · Show the back-office obravnava on the phone — a warden sees the verdict but not the reasoning
`✨ Enhancement` · `P2` · **Half 1 `Done`** (ORDS live + verified, shipped v1.6.0+15, rolled out 2026-08-31; presentation defect fixed in TB-29, shipped v1.7.0+16 2026-08-31) · **Half 2 `Blocked`** · Updated: 2026-08-31

- **Problem.** Since narcis-vibed **NV-220** (live 2026-08-26) the web backoffice records a case
  review against `TB_MOTNJE`: `STATUS_OBRAVNAVE`, plus `OPOMBA_URADNA` (an official note),
  `OBRAVNAVAL` (who) and `OBRAVNAVANO` (when). This app shows the **status** and nothing else, so a
  warden watches their own disturbance flip to *Zaključeno* with no idea who closed it, when, or
  why. They get the verdict without the reasoning, which is the weaker half of a review loop.
- **⚠️ IT IS A TWO-PART CHANGE — the data does not even reach the phone today.** The list handler in
  [`tools/ords/disturbance_endpoints.sql`](../tools/ords/disturbance_endpoints.sql) selects an
  explicit column list that ends at `status_obravnave` (line ~124-125), so the three review columns
  never leave Oracle for this client. Widening that `SELECT` + its `APEX_JSON` writes is step one;
  `RemoteDisturbance`/`Disturbance` + the detail UI is step two. Contrast **TB-27**, which is
  client-only.
- **Scoped in two halves deliberately, because only one of them is obvious:**
  1. **Status + who + when** — uncontroversial, and closes most of the loop. `OBRAVNAVAL` is an
     e-mail and `OBRAVNAVANO` an ISO-8601 UTC instant (same shape as `ustvarjen`, so
     `fmtDateTime`-equivalent handling already exists). Read-only on the phone: the web owns these
     columns and this app must not write them (see TB-25).
  2. **`OPOMBA_URADNA` itself** — ❓ **a product decision, not a technical one.** narcis-vibed's
     manual currently states *"Opomba je interna: prijavitelj motnje je ne vidi"*, but that sentence
     was **copied by analogy from the hornet module, where the reporter is a member of the public**.
     Here the reporter is your own field inspector, and "internal" plausibly includes them. Against
     showing it: the note may carry candid judgements about that inspector's own report, which is a
     different thing from a case summary. **Decide this before building half 2**; half 1 can ship
     without it.
- **If half 2 is approved, narcis-vibed must change in the same breath** — its manual sentence
  becomes false the moment the phone renders the note, and that repo's NV-48 rule makes the manual
  part of the deliverable.
- **Needs a release** (ORDS re-publish for step one, then a Flutter build) — this app's own cycle.
- **History is NOT available and will not be.** Only the latest review is stored; there is no log of
  prior statuses or notes (narcis-vibed, decided 2026-08-26: *"leave it this way for now"*). So the
  phone can show *"last reviewed by X on Y"* and never *"what it said before"*.

- **Decision (2026-08-31, maintainer): ship half 1 only. `OPOMBA_URADNA` stays server-side.** The
  warden sees status + who + when; the reviewer's note does not cross the wire to this client at all
  (it is not even SELECTed). This needs **no change in narcis-vibed** — its manual sentence
  *"Opomba je interna: prijavitelj motnje je ne vidi"* stays true. **Half 2 remains `Blocked`** on the
  product call: may the inspector who filed the record read the reviewer's note about it?
- **Implemented — half 1 (2026-08-31, in source; ORDS deploy + Flutter release both pending):**
  - **Server.** GET-list handler in [`disturbance_endpoints.sql`](../tools/ords/disturbance_endpoints.sql)
    widened to `SELECT … obravnaval, obravnavano` and to emit `reviewedBy` / `reviewedAt`.
    `OPOMBA_URADNA` deliberately not selected. Handler-only re-publish — **no DDL, no schema change,
    no new grant**. Runbook: [`tools/ords/TB-26_DEPLOY.md`](../tools/ords/TB-26_DEPLOY.md).
  - **⚠️ Timezone, and it nearly went wrong.** This item claimed `OBRAVNAVANO` was "same shape as
    `ustvarjen`". True, but for a non-obvious reason worth recording: narcis-vibed's DDL states
    *"OBRAVNAVANO IS A PLAIN TIMESTAMP HOLDING UTC"*, and TB-14 established the ORDS session runs at
    UTC — which is what makes `SYS_EXTRACT_UTC(CAST(col AS TIMESTAMP WITH TIME ZONE))` a **pass-through**
    for UTC-stored naive columns. So `reviewedAt` uses the identical serializer as `createdAt`. A
    `FROM_TZ` shift would have moved every review stamp by the host offset (+2 h in summer).
  - **Client.** `reviewedBy` / `reviewedAt` added to `Disturbance` + `RemoteDisturbance`
    (nullable; absent ⇒ not yet reviewed, since APEX_JSON elides NULL keys). Rendered on
    [`detail_screen.dart`](../lib/screens/detail_screen.dart) as two pills beside the status pill,
    date in **local** time (TB-13). **Read-only by construction:** `_payload` in
    [`remote_api.dart`](../lib/data/remote_api.dart) is an explicit allowlist and omits both, so the
    phone cannot clobber a reviewer's decision (TB-25's warning) — regression-tested.
  - **Cross-repo hazard now cuts both ways** — the schema-header note in
    [`disturbance_schema.sql`](../tools/ords/disturbance_schema.sql) said *"this app never reads or
    writes them"*, which this change makes false. Corrected: a clean rebuild from that file alone now
    also breaks **this app's** `GET /disturbances/` with `ORA-00904`, not only the web module.
  - **Tests:** 6 new in `test/remote_api_test.dart` (parse, absent ⇒ null, local-store round-trip,
    pre-TB-26 cache rehydrate, and *"the review fields NEVER go back on the wire in a write"*).
    Suite **117/117**, `flutter analyze` clean (10 pre-existing info lints, unchanged).
  - **Deploy order is free.** Older app ignores the new keys; newer app reads them as null until the
    handler ships. Neither side is breaking.
- **Built into v1.6.0+15** (2026-08-31, archived `~/Releases/terenska-beleznica-1.6.0+15.aab`, signed with the
  upload key — signer SHA-256 matches `STATE.json`).
- **ORDS DEPLOYED + VERIFIED on prod, 2026-08-31** (maintainer-run via APEX SQL Workshop), checked
  read-only with the new [`verify_tb26.sh`](../tools/ords/verify_tb26.sh): `GET` 200 over 74 records with
  the pre-existing payload intact · one reviewed record returns `reviewedBy` + a Z-tagged `reviewedAt`
  (`caaaf260…`, `2026-08-27T07:08:35.963Z`) · **`opomba` appears nowhere in the body**, so half 2 is
  confirmed not leaking.
- **The timezone is proved, not eyeballed — and that mattered.** Comparing `reviewedAt` against the web
  backoffice would only have compared two *renderings*; had both applied the same wrong conversion it
  would have read as correct. So the script re-runs **TB-14's own diagnostic** instead, comparing a
  server-stamped instant against a client-supplied one on the same row: across the 10 most recent walks
  `createdAt − endedAt` spans **−0.3 s … +1.0 s** (the POST delay), where a session-offset shift would
  read ~3600 s / ~7200 s. `TB_OBHODI.USTVARJEN` and `OBRAVNAVANO` are both stamped
  `SYS_EXTRACT_UTC(SYSTIMESTAMP)` and read through the identical serializer, so `reviewedAt` is honest UTC.
- **Shipped:** ORDS live 2026-08-31; client in v1.6.0+15, **rolled out on the Play Closed testing track
  2026-08-31**.
- **⚠️ The v1.6.0+15 presentation was wrong, and a user said so immediately (fixed in TB-29).** The review
  fields shipped as two **unlabelled pills** sitting among the action pills — a bare e-mail and a bare
  date. The data was right and the warden still could not tell what they were, which is most of the
  original problem restated. Replaced with an `_ObravnavaCard`: a titled block, every value labelled,
  `caseStatus` moved in beside them with its TB-27 colour dot, and an explicit *"Zapis še ni bil
  obravnavan."* when unreviewed. Lesson worth keeping: *the field reaching the screen is not the feature
  landing* — half 1's whole point was that a verdict without context is the weaker half of a review loop,
  and an unlabelled date is exactly that.

### TB-27 · Colour the map dots by status obravnave, not age — restore parity with the web
`✨ Enhancement` · `P2` · `Done` (shipped v1.6.0+15; rolled out on the Play Closed testing track 2026-08-31, confirmed working on device; two follow-up defects fixed in TB-29, shipped v1.7.0+16 2026-08-31) · Updated: 2026-08-31

- **Wanted (user, 2026-08-26):** match narcis-vibed **NV-221**, which moved the web's disturbance
  dots from age-colouring to **status obravnave** colouring.
- **Why this is a restoration, not a divergence.** narcis-vibed **NV-81** originally coloured its
  dots by age *specifically for parity with this app* (red ≤31 d / orange ≤365 / blue older).
  NV-221 reversed that on the user's request and **accepted the loss of parity as its stated cost**.
  Doing the same here makes that cost temporary: the two apps agree again, at status instead of age.
- **⚠️ CLIENT-ONLY — no ORDS change needed.** Unlike TB-26, the data is already here: the list
  handler returns `status_obravnave` and `Disturbance.caseStatus` already holds it. One marker-colour
  expression is the core of it, at
  [`lib/screens/home_screen.dart`](../lib/screens/home_screen.dart) ~line 657, whose own comment
  states the current rule (*"Color encodes age … shape encodes authorship"*).
- **Reuse the web's exact palette** so the two apps cannot disagree about what *Zaključeno* looks
  like — `STATUS_COLORS` in narcis-vibed `web/src/lib/trsca/format.ts`: amber `#d97706` Odprto ·
  blue `#0a84ff` V obravnavi · green `#1b7a1b` Zaključeno · gray `#8e8e93` Predano drugi službi.
- **Keep unchanged, deliberately:** shape = authorship (own = filled disc, teammate = ring); the
  white halo (it is what makes any fill legible on any basemap — measured on the web side); and the
  **youngest-renders-on-top sort** (`sorted` by `observedAt` ascending, since `flutter_map` draws in
  list order) — a stacking rule worth keeping whatever the fill encodes, and leaving it alone means
  this change cannot shift the draw order. `ageBucketOf` and the **Starost** filter both stay.
- **⚠️ THE REAL SCOPE QUESTION, and it is not the colour.** The filter sheet offers **Starost ·
  Avtor · Obdobje** and has **no Status dimension at all** — NV-81 called the status facet a
  "deliberate web-only review facet". So after this change the colour would encode something the
  warden can neither filter by nor look up. Either add a **Status** section to
  [`motnje_filter_sheet.dart`](../lib/widgets/motnje_filter_sheet.dart) (which the web treats as its
  legend), or ship the standing *on-map legend* follow-up first. Colour without a key is worse than
  the age colouring it replaces.
- Also note `lib/data/disturbance_filter.dart:4` claims the age thresholds *"match the legend the
  warden sees"* — check what that legend actually is and update the comment, or it will describe a
  legend that no longer means age.
- **Needs a Flutter release.** Pairs naturally with TB-26 in one build.

- **The scope question resolved itself once the code was read (2026-08-31).** *"Add a Status section
  or ship the on-map legend first"* was a false choice: **there is no on-map legend and never was.**
  The comments in `disturbance_filter.dart:4` and `basemap.dart:176` that referred to "the legend the
  warden sees" pointed at the **filter sheet itself**, whose `_bucketRow` already draws a colour
  swatch beside each Starost option. So a **Status** section with swatches *is* the legend, using a
  pattern already in that file — no separate legend item needed, and the standing on-map-legend
  follow-up is no longer a prerequisite for this.
- **Implemented (2026-08-31, in source; Flutter release pending):**
  - `recordMarkerColorForStatus` in [`basemap.dart`](../lib/widgets/basemap.dart), wired into
    `_buildMarkers` ([`home_screen.dart`](../lib/screens/home_screen.dart)). Palette **verified
    against narcis-vibed source**, not transcribed from this item: `STATUS_COLORS` in
    `web/src/lib/trsca/format.ts` — amber `#d97706` · blue `#0a84ff` · green `#1b7a1b` · gray
    `#8e8e93`, **including its `?? "#8e8e93"` fallback**, so a fifth status added server-side draws
    gray rather than throwing.
  - **Status section** added to [`motnje_filter_sheet.dart`](../lib/widgets/motnje_filter_sheet.dart),
    swatches drawn from `recordMarkerColorForStatus` itself so legend and map cannot drift. It is
    **never hidden** when all loaded records share one status (unlike Avtor/Kategorija, which are
    choice lists) — precisely because it is the legend.
  - `MotnjeFilter` gained a `statuses` dimension. A record whose status is **outside** the four known
    values is **never hidden** by it: an unknown status silently vanishing off the map is a worse
    failure than an unfilterable dot.
  - Kept unchanged as this item required: authorship-by-shape, the white halo, and the
    youngest-on-top sort. `ageBucketOf` + the Starost filter stay; `recordMarkerColorForAge` survives
    as that filter's swatch source.
  - Stale comments fixed: `disturbance_filter.dart:4` (no longer claims the map encodes age) and the
    class doc, which said "three dimensions" while there were already four — now five.
  - **Tests:** new `test/record_marker_color_test.dart` pins the four hex values so a drift from
    narcis-vibed fails here; 6 status-dimension tests in `test/disturbance_filter_test.dart`; 2 sheet
    tests. Two pre-existing sheet tests needed `ensureVisible` — the taller sheet pushed their targets
    below the fold. Suite **117/117**.
- **⚠️ narcis-vibed now carries a stale comment of its own:** `web/src/lib/trsca/format.ts` (~line 54)
  still says *"The field app (narcis-nadzorniki) colours disturbance dots by AGE, not status"*. That
  becomes false when this ships. Worth an NV item.
- **Built into v1.6.0+15** (2026-08-31, archived `~/Releases/terenska-beleznica-1.6.0+15.aab`, signed with the
  upload key). **Needs no server change** — unlike TB-26 it works the moment the build is installed.
- **Shipped:** v1.6.0+15, **rolled out on the Play Closed testing track 2026-08-31**; confirmed working on
  device — changing a record's status in the back office changes its dot colour on the phone.
- **⚠️ Two defects this pass missed, both found on the rolled-out build and fixed in TB-29:**
  1. **The walk-detail map was left colouring by age.** TB-27 was scoped as "one marker-colour expression"
     and that was wrong — [`walk_detail_screen.dart`](../lib/screens/walk_detail_screen.dart) draws
     disturbance dots too, so for one release the two maps encoded the *same dot* by different rules.
  2. **Two colour legends at once.** Keeping Starost (red/orange/blue swatches) beside the new Status
     swatches read as two competing legends. Resolved by removing Starost — see TB-29.
### TB-35 · A confirmed delete still showed as unsynced — and the test that should have caught it was vacuous
`🐞 Bug` · `P1` · `Doing` (fixed, **needs a release**) · Reporter: Alexis (on the rolled-out v1.10.0+19) · Updated: 2026-09-02
- **Problem:** On v1.10.0+19 the delete worked, but the reporter had to hit sync manually before the app
  agreed it had. Claude had asserted the delete syncs immediately; the reporter said it did not, and was
  right about the observable behaviour.
- **Root cause — the indicator, not the delete.** The DELETE *did* go out and succeed in the same tap.
  But `_drainPendingDeletes` purged the row from `_records` while leaving its id in `_lastRemoteIds`, the
  snapshot of what the last pull said the server holds. `missingLocalCount` counts ids in that snapshot
  with no local row, so it became 1 → `pendingCount` 1 → the sync icon flipped to the orange
  `cloud_download` *"Prenesi z strežnika (1 manjkajočih)"* state. Tapping sync ran a pull, which
  refreshed the snapshot and turned it green. **From the user's seat that is indistinguishable from a
  delete that never synced** — the app said there was outstanding work, so there was no reason to
  believe otherwise.
- **Fix:** drop the id from `_lastRemoteIds` at the moment the row is purged. **`deleteWalk` had the
  identical defect** (pre-dating the delete queue — it removes the walk locally and never touched
  `_lastRemoteWalkIds`), fixed in the same pass, but **only on a confirmed server delete**: a walk
  removed locally whose DELETE failed genuinely *is* missing locally, and the badge saying so is right.
- **⚠️ The bigger finding: TB-2's load-bearing test was not testing anything.** The booted-`AppState`
  harness built the mock GET body with `http.Response(String, status)`, which encodes the body using the
  encoding named in the content-type header and **defaults to latin-1**. The fixtures contain
  `Natančna`, so the constructor threw `Invalid argument (string): Contains invalid characters`,
  `fetchRecords` wrapped it as a network `RemoteApiException`, and `_pullRemote` swallowed it **by
  design** (a failed pull is meant to be non-fatal). Net effect: **every pull in every harness test
  silently never ran.** So:
  - *"a failed delete stays queued and the pull does NOT resurrect it"* — described in TB-2 as the
    load-bearing regression test — passed without ever executing the merge it claimed to exercise.
  - `_lastRemoteIds` was always null, which is why this badge bug could not surface in tests either.
  - The mock needs `headers: {'content-type': 'application/json; charset=utf-8'}`. There is now a
    `_json` helper carrying that, and a `the harness pull actually works` test guarding the harness
    itself, because a silently-swallowed pull is invisible by construction.
  - **Both fixes were then verified by removal**: with the `_lastRemoteIds` line deleted the badge test
    fails `Expected: <0> Actual: <1>`; with the merge's `pendingDelete` branch deleted the resurrect test
    fails `Expected: empty Actual: [Instance of 'Disturbance']`. Neither had been checked that way
    before, which is the whole reason a vacuous test survived. **Do this for any test whose job is to
    catch a specific defect.**
- **Lesson, stated plainly:** the first thing to establish about a mock-backed test is that the mock is
  actually being reached. A swallowed error inside production code — here a deliberately non-fatal
  pull — will make a test pass for the wrong reason and keep passing.
- **Tests:** `the harness pull actually works`, `a confirmed delete leaves the sync badge clean`, and
  `a FAILED delete still reports honestly` (the mirror case: queued row → `pendingPushCount` 1 and
  `missingLocalCount` 0, so the badge is right in both directions). Suite **148/148**.
- **Shipped:** —

### TB-33 · Delete never reached the server — ORDS 400 on every bodyless DELETE
`🐞 Bug` · `P1` · `Done` (shipped v1.10.0+19, rolled out on the Play Closed testing track 2026-09-02; **delete confirmed working on device**) · Reporter: Alexis (on the rolled-out v1.9.0+18) · Updated: 2026-09-02
- **Problem:** On v1.9.0+18 a delete disappeared from the phone and **never synced**. The queue worked
  exactly as designed — it held the row, retried on every sync, and did not lose it — but every attempt
  failed, so the record stayed on the server indefinitely. Reproduced on a record created two minutes
  earlier, so nothing to do with old or migrated rows.
- **Root cause — the client, not the server.** `RemoteApi._jsonHeaders` put
  `Content-Type: application/json; charset=utf-8` on **every** request, including bodyless ones. ORDS
  parses the request payload for a body-bearing method as soon as a JSON content type is declared, and an
  empty body is not valid JSON, so the `DELETE` was rejected by **ORDS itself before the PL/SQL handler
  ran**: `400 {"code":"BadRequest","message":"Expected one of: <<{,[>> but got: <<EOF>>"}`. That 400 is
  not in §9.3's DELETE row because the handler cannot produce it — it returns only 204/401/404/500.
- **How it was diagnosed.** The device log (`OPERATIONS.md` → Sync diagnostics, whose delete lines were
  added the day before for exactly this) gave `delete <uuid> FAILED, stays queued:
  RemoteApiException(400): {` on a loop. Then two unauthenticated `curl` DELETEs against the all-zeros
  UUID in production — the same probe [`test_disturbances.sh`](../tools/ords/test_disturbances.sh) runs
  first, safe because auth is checked before any DML — isolated the variable: **401 without the header,
  400 with it.**
- **⚠️ Why nothing caught it for months.** Three things lined up:
  1. `GET` survives the bad header — ORDS does not attempt payload parsing on GET — so the whole app
     looked healthy.
  2. The disturbance `DELETE` had **no UI path until TB-2**, so no bodyless Dart request was ever sent in
     anger. `updateRecord` was equally unexercised.
  3. [`test_disturbances.sh`](../tools/ords/test_disturbances.sh) adds `Content-Type` **only when it
     sends a body**, so the endpoint's own smoke test passed every time — which is how §9.3 came to call
     DELETE "smoke-tested" while the client could not call it at all.
  **The lesson worth keeping: a curl smoke test passing is not evidence the Dart client's request shape
  is right.** The two were never compared.
- **Fix:** split the headers by verb — `_authHeaders` (auth + `Accept`) for GET/DELETE, `_jsonHeaders`
  (adds `Content-Type`) for POST/PUT. **Also fixed `deleteWalk` and `deletePhoto`**, which carried the
  identical defect and had never been exercised either — two latent bugs closed alongside the reported
  one. Documented in ARCHITECTURE §9.3.
- **Tests:** a `the Content-Type contract` group in
  [`remote_api_test.dart`](../test/remote_api_test.dart) asserts that no bodyless request declares a
  Content-Type (and still authenticates), and that POST/PUT still do. Asserting the header contract
  per verb is the check that was missing — the existing `deleteRecord` tests never looked at headers.
  Suite **145/145**.
- **No data was lost.** Queued deletes are persisted, so the rows still marked `pendingDelete` on the
  device drain by themselves on the first sync after the fixed build is installed. Nothing to clean up
  by hand.
- **Built into v1.10.0+19** (2026-09-02, archived `~/Releases/terenska-beleznica-1.10.0+19.aab`, signed
  with the upload key). Build exit 0; analyze at the documented 10 info lints; suite **145/145**; signer
  cert SHA-256 matches `upload_cert_sha256`; versionName 1.10.0 in the AAB manifest (1.9.0 absent),
  versionCode 19; manifest otherwise identical to v1.9.0+18. **No server change** — the ORDS handler was
  correct all along.
- **Shipped:** v1.10.0+19, **rolled out on the Play Closed testing track 2026-09-02** — delete confirmed reaching the server on device.

### TB-34 · Delete from the record details view, not just the list row
`✨ Enhancement` · `P2` · `Done` (shipped v1.10.0+19, rolled out 2026-09-02) · Reporter: Alexis · Updated: 2026-09-02
- **Problem:** TB-2 put delete only on the *Seznam zapisov* row, which shows a type and a date. That is
  rarely enough to be sure which record you are looking at — the reporter's point is that **most delete
  decisions are actually made in the details view**, where the photos, location and time are visible.
- **Want:** The same delete action in the details view.
- **Built:** the identical `RecordActionsMenu` in `DetailScreen`'s AppBar — deliberately the *same*
  widget, so the confirm dialog and the `isLockedByReview` refusal cannot drift apart between two entry
  points. It gained an `onDeleted` callback: the list needs nothing (the row vanishes on its own because
  `AppState.records` hides it) but the detail screen must pop, or it would sit there showing a record
  that no longer exists. The `ScaffoldMessenger` is captured **before** the pop, or the confirmation
  snackbar would go with the route.
  - Shown for **own records only** — the list is author-scoped but the home map is not, and the server
    gate is org-wide (see TB-32). Hidden in TB-31's preview mode, where there is nothing to delete yet.
  - Moved to [`lib/widgets/record_actions_menu.dart`](../lib/widgets/record_actions_menu.dart): with two
    screens using it, leaving it in `record_list_screen.dart` made the two screens import each other.
- **Built into v1.10.0+19** alongside TB-33's fix.
- **Shipped:** v1.10.0+19, **rolled out 2026-09-02**.

### TB-32 · Edit a disturbance from the phone
`✨ Enhancement` · `P2` · `Blocked` · Reporter: Matjaž (via TB-2) · Updated: 2026-09-02
- **Problem:** Split out of [TB-2](#tb-2--delete-disturbance-entries-from-the-phone) on 2026-09-02. A
  warden who spots a wrong type, time or description on a saved record still has to go to the desktop
  back office. TB-31's preview catches mistakes *before* the commit; this is the after.
- **Want:** Edit a own record's fields from *Seznam zapisov* — the same form, prefilled, saving over the
  existing `motnja_id`.
- **⚠️ This is not a UI task. Three things sit under it:**
  1. **The phone's PUT clobbers the back office's case decision — needs an ORDS change.** The handler
     writes `status_obravnave = l_case_status` and `obhod_id = l_obhod_id`
     ([`disturbance_endpoints.sql:580`](../tools/ords/disturbance_endpoints.sql)). A warden fixing a typo
     would push their possibly-stale local status over a reviewer's verdict, silently reopening a closed
     case. It does **not** touch `obravnaval`/`obravnavano`/`opomba_uradna`, so those are already safe.
  2. **The web side has already decided the rule, and its reasoning names this app.** From
     `narcis-vibed` `project/ARCHITECTURE.md` (verified against source 2026-09-02, not paraphrased):
     *"`STATUS_OBRAVNAVE` and the three obravnava columns belong to NV-220's handler and its different
     gate — an author must not close their own case from the edit form, which is the same concern
     NV-220's follow-up raised about the phone's create-time status dropdown. `OBHOD_ID` is refused
     outright: on an absent-means-null wire, a panel that forgot to echo it would silently unlink the
     record from its patrol walk."* It **does** write `SPREMENJEN`/`SPREMENJEN_OD`. Match those rules
     rather than inventing new ones, and check whether that handler shipped before designing the phone's.
  3. **Offline edits are not queued.** `updateRecord` is still fire-and-forget, and the merge treats the
     server as authoritative — so an offline edit silently reverts on the next pull, the same class of
     bug TB-2 fixed for delete. Delete needed one boolean; edit needs field-level reconciliation, or a
     documented last-write-wins with the window made visible to the user.
- **Also worth settling:** the phone's own create-time `caseStatus` dropdown
  ([`form_screen.dart`](../lib/screens/form_screen.dart)) is the thing NV-220's follow-up objected to. If
  status is web-owned, that dropdown probably should not exist either — decide both together.
- **Server gate is org-wide, not author-scoped.** PUT/DELETE 404 only across organisations, so the UI is
  the only thing stopping a warden editing a teammate's record. Fine while *Seznam zapisov* lists own
  records only; worth an author check server-side if edit ships.
- **Reusable from TB-2:** the booted-`AppState` test harness in
  [`record_delete_test.dart`](../test/record_delete_test.dart) (fake stores/auth/connectivity/photos +
  `MockClient`) is what any queue test for this needs.
- **Discussion — BLOCKED on two decisions:** (a) does the ORDS PUT stop writing `status_obravnave`/
  `obhod_id` for everyone, or does the phone get a separate edit-scoped endpoint? (b) which fields are
  editable — text and types only, or location/time/photos too? Location and time are what a
  contested record turns on, so editing them silently is a different risk from fixing a typo.
- **Shipped:** —

### TB-31 · Preview the record before saving, with a way back to editing
`✨ Enhancement` · `P2` · `Done` (shipped v1.8.0+17; rolled out on the Play Closed testing track 2026-09-02) · Reporter: Alexis · Updated: 2026-09-02
- **Problem:** In [`form_screen.dart`](../lib/screens/form_screen.dart) *Shrani zapis* commits and pops
  in one tap — there is no review step and no undo. After that the only correction path is the desktop
  back office, because TB-2 (edit/delete on the phone) is still `Todo`. The warden's last look at the
  record is a column of form fields, not the record.
- **Want:** A preview step between the form and the commit that renders the record exactly as
  *Podrobnosti zapisa* will, with two actions: back to editing, or save.
- **Context — the client already has both halves, so this is small:**
  - `_save()` ([`form_screen.dart:340`](../lib/screens/form_screen.dart)) already validates, then builds
    the complete `Disturbance`, then calls `addRecord` + `pop`. The change is splitting it at the
    `addRecord` line: validate → build → push preview → save from the preview's callback.
  - `DetailScreen` takes a plain `Disturbance`, and `_liveRecord()`
    ([`detail_screen.dart:55`](../lib/screens/detail_screen.dart)) falls back to `widget.record` when the
    id is absent from `state.records` — which is exactly the unsaved-preview case. It renders an
    uncommitted record as-is.
  - `_ensurePhotos()` ([`detail_screen.dart:43`](../lib/screens/detail_screen.dart)) skips photos that
    have a `localPath` **or** `pendingUpload: true`. A fresh form's photos are both, so the preview does
    no network work.
  - Push the preview **on top of** the form. `_FormScreenState` holds all the field state, so popping
    back restores the filled form for free. Never pop-and-re-push the form.
- **Two blocks must be suppressed in preview** (suggest a `preview: true` flag on `DetailScreen`):
  1. **`_SyncBadge`** reads `record.pendingSync`, which the form sets `true` — it would announce
     "queued to sync" for a record that does not exist yet.
  2. **`_ObravnavaCard`** (TB-26/TB-29) would render *"Zapis še ni bil obravnavan"*, trivially true of
     every unsaved record and pure noise at the moment of commit.
- **Adjacent defect found while scoping this — likely TB-2's duplication root cause.** `_save` has **no
  in-flight guard**: `FilledButton.icon(onPressed: _save)` stays enabled while `addRecord`
  ([`app_state.dart:346`](../lib/state/app_state.dart)) awaits photo materialisation, the optimistic
  POST **and** the photo uploads — seconds on a weak link. A second tap re-enters `_save`, mints a
  second `_uuid.v4()` and files a second record. That matches TB-2 sub-task 1 ("POST is idempotent on
  the client UUID, so duplicates mean the client minted multiple records… likely a double-tap on save")
  exactly. Fix it in this pass whether or not the preview ships.
- **Discussion — RESOLVED 2026-09-02: mandatory.** The alternative (*Predogled* beside *Shrani*) is
  skipped by precisely the careless case that produces bad records. Built as mandatory with the save
  living on the preview, so it reads "review → save" rather than "save → are you sure"; the net cost is
  one tap in place of a blind commit.
- **Relation to TB-2:** complementary, not a substitute. Preview catches what the warden notices *before*
  committing; TB-2 covers everything noticed after. **This does not reduce TB-2's priority** — it is
  still `P1`, and the desktop back office is still the only way to fix a saved record.
- **Built 2026-09-02** — client-only, no ORDS/DB/schema change, no wire-payload change:
  - [`form_screen.dart`](../lib/screens/form_screen.dart) — `_save` → `_openPreview`: same validation,
    same `Disturbance`, but it pushes the preview instead of committing. Button is now
    *Preglej in shrani*. A `_previewOpen` flag stops a double-tap stacking two preview routes (saving
    from the top one would pop back into the second preview instead of out of the form).
  - [`detail_screen.dart`](../lib/screens/detail_screen.dart) — `preview` + `onSave` params
    (`assert(!preview || onSave != null)`), title *Predogled zapisa*, `_SyncBadge` and `_ObravnavaCard`
    hidden, and a `bottomNavigationBar` action bar: *Uredi* / *Shrani zapis*. The bar adds
    `viewPaddingOf().bottom` itself — Scaffold does not apply the gesture inset to that slot
    (ARCHITECTURE §15, pattern 1b).
  - **The double-tap guard** — `_handleSave` sets `_saving`, disables the button for the whole await,
    and shows *Shranjujem...*. See the TB-2 note below.
  - Tests: [`preview_before_save_test.dart`](../test/preview_before_save_test.dart) (4) and
    [`form_preview_flow_test.dart`](../test/form_preview_flow_test.dart) (3). The latter pins the claim
    that *Uredi* returns to a **filled** form — the failure mode a pop-and-re-push refactor would
    reintroduce silently. Full suite **132/132**; `flutter analyze` clean (the 10 remaining infos are
    all pre-existing).
  - **Not verified on a device.** Analyzer + widget tests only; the narrow-screen test (320 px) covers
    the action-bar layout, but the real gesture-bar check per ARCHITECTURE §15 needs a device — it is on
    the hand-over checklist for this release.
- **Built into v1.8.0+17** (2026-09-02, archived `~/Releases/terenska-beleznica-1.8.0+17.aab`, signed with
  the upload key). Build exit 0; analyze at the documented 10 pre-existing info lints; suite **133/133**;
  signer cert SHA-256 matches `upload_cert_sha256` with Owner `CN=Terenska beleznica`; versionName 1.8.0 in
  the AAB manifest (1.7.0 absent), versionCode 17 from `packaged_manifests`; `com.example` and
  `ACCESS_BACKGROUND_LOCATION` absent; all four `hardware.camera*`/`location*` features present.
  **Needs no server change** — it works the moment the build is installed.
- **Shipped:** v1.8.0+17, **rolled out on the Play Closed testing track 2026-09-02**.
- **Verified on device 2026-09-02.** The gesture-bar check ARCHITECTURE §15 requires for new
  bottom-of-screen chrome is **done**: on the A56, the *Uredi* / *Shrani zapis* row clears the navigation
  bar. That closes the last open verification on this item — the action bar is the app's first
  `bottomNavigationBar`, so the pattern is now confirmed, not just reasoned about (§15 pattern 1b).

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

### TB-25 · TB_MOTNJE gained three columns this repo does not create — record that, and who owns the status
`🔧 Chore` · `P3` · `Done` · Updated: 2026-08-26

- **Context:** narcis-vibed **NV-220** taught its Terenska beležnica backoffice to record a case-review
  decision — `STATUS_OBRAVNAVE` plus a new internal note and audit stamp — against the live `TB_MOTNJE`
  rows this app writes. That needed three new columns: `OPOMBA_URADNA`, `OBRAVNAVAL`, `OBRAVNAVANO`.
- **Where the migration lives, and why not here:** in that repo, `ords/vibed_trsca_ddl.sql`, because the
  web review surface is the **only** writer of those three columns. But
  [`tools/ords/disturbance_schema.sql`](../tools/ords/disturbance_schema.sql) is the authority on this
  table's shape, so without a note it would quietly misdescribe production — and a clean rebuild from it
  would drop three columns the web module SELECTs and UPDATEs, whose absence surfaces only as an opaque
  HTTP 555 on that module's first request.
- **Done (2026-08-26, commit `dea297d`):** a comment block in the schema header naming the three columns,
  their owner and the rebuild dependency. **Comment only** — no schema change, no behaviour change, no
  release.
- **The other half: `STATUS_OBRAVNAVE` is now owned by the web.** This app still *displays* it and still
  sets an initial value on **create**, but it never updates an existing row — `AppState.updateRecord` and
  `AppState.deleteRecord` have **no callers**, the create `POST` is skip-if-exists rather than an upsert,
  and `FormScreen` is create-only. So the two writers cannot collide and **no release was needed** for
  NV-220. ⚠️ If an edit path is ever wired up here, `PUT /disturbances/:id` needs a **precondition**
  first — today it is a full-record replacement with none, which would silently overwrite a reviewer's
  decision.
- **Open question for the product owner (not a blocker):** the create form still offers the full status
  dropdown, so an inspector can file a record already marked *Zaključeno*. Now that case handling is a
  back-office act, that may be worth removing — a one-line change in `remote_api.dart` plus the dropdown,
  on this app's own release cycle.

