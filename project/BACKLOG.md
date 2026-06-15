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
`🐞 Bug` · `P2` · `Blocked` (needs discussion) · Reporters: Tomaž, Matjaž · Updated: 2026-06-03
- **Problem:** Walk (obhod) track points scatter off the actual road/path even with good
  GPS reception.
- **Context:** Track points come from `Geolocator.getPositionStream` (5 m distance filter)
  in [`home_screen.dart`](../lib/screens/home_screen.dart); each point stores its `accuracy`
  and is POSTed once at walk end (`walks/` — points are write-once server-side). Levers are
  client-side: drop low-accuracy points, smooth the polyline, or snap-to-road. Cannot fix
  the underlying signal — partly device/physics-bound.
- **Discussion:** Pin the achievable target before estimating — accuracy filtering +
  polyline smoothing (in-app, cheap) vs. snap-to-road (needs a routing service, heavier).
  How bad is "occasionally"? A sample bad track would help.
- **Shipped:** —

### TB-4 · Default disturbance location to the device's current position
`✨ Enhancement` · `P2` · `Todo` (quick win) · Reporters: Tomaž, Matjaž · Updated: 2026-06-03
- **Problem:** Setting an accurate location takes two manual steps — the app offers an
  approximate point, the satellite icon refines it (step 1), and a manual map tap gives the
  exact spot (step 2).
- **Want:** Make step 1 automatic so the new entry defaults to the phone's current position
  (the blue device dot); keep the manual map tap as an optional fine-tune. Tomaž's wording:
  "the app should first offer, as the disturbance location, the location where the phone is
  at that moment."
- **Context:** Entry/refine flow lives in [`form_screen.dart`](../lib/screens/form_screen.dart)
  and [`location_picker_screen.dart`](../lib/screens/location_picker_screen.dart);
  `locationAccuracy` is `Natančna` / `Približna`. The live fix already exists on the home map
  ([`home_screen.dart`](../lib/screens/home_screen.dart) `[gps]` stream) — this is wiring that
  fix in as the form's default. Self-contained UX change.
- **Discussion:** —
- **Shipped:** —

### TB-6 · Toggle and filter historical entries on the map
`✨ Enhancement` · `P2` · `Todo` · Reporters: Tomaž, Rudi · Updated: 2026-06-03
- **Problem:** In places there are so many historical points that they obscure the map and
  hurt readability.
- **Want:** A show/hide toggle for historical-entry points, plus filtering by
  year / reporter / disturbance category.
- **Context:** The home map already layers the org's `Motnje` records and the bundled legacy
  set (`assets/legacy/notranjski_park_2025.json`, 703 rows) and has a chip-toggle pattern
  (basemap, Parcele) to copy — see [`home_screen.dart`](../lib/screens/home_screen.dart).
  Natural split: **(a)** a visibility toggle (cheap, high daily value) and **(b)** the
  year/reporter/category filters (a filter UI + predicate over records — larger). Consider
  shipping (a) first.
- **Discussion:** —
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

### TB-10 · Natura 2000 ("Območja") map overlay
`✨ Enhancement` · `P2` · `Doing` · Maintainer-initiated · Updated: 2026-06-15
- **Want:** Bring the `narcis-vibed` "Območja s statusom" layers to the field app, starting
  with Natura 2000, as a toggleable map overlay with tap → list → detail.
- **Decisions:** Server-rendered **WMS tiles** from the production NarcIS GeoServer
  (`narcis.gov.si/ows/ows`, layer `SI.NARCIS:ZOS_N2K_PLG`, the same GeoServer the APEX app uses),
  with tap-to-identify via WMS GetFeatureInfo. Pivoted here from an initial client-side vector
  approach (GeoJSON from the ORDS `vib/zos` module + `proj4dart`) after measuring that endpoint at
  **~14–16 s TTFB per cold request** and recognising whole-layer vector won't scale to NV/NVJ. WMS
  tiles load per-viewport (instant first paint) and scale to any layer. See ARCHITECTURE §10.2.
- **Shipped (code):** [`obmocja_store.dart`](../lib/data/obmocja_store.dart) (`identify` →
  GetFeatureInfo + `ObmocjeFeature`), `obmocjaWmsLayers()` in
  [`basemap.dart`](../lib/widgets/basemap.dart), [`obmocje_sheet.dart`](../lib/widgets/obmocje_sheet.dart)
  (list ⇄ detail), wired into [`home_screen.dart`](../lib/screens/home_screen.dart) (the "Območja"
  chip toggles the tile layer instantly; a map tap runs identify). `proj4dart` removed. Unit tests
  in `test/obmocja_store_test.dart` (GetFeatureInfo request shape + overlapping-feature parse) —
  suite 39/39 green.
- **Open before Done:** (1) on-device check on the A56 — tiles render with the official Natura
  symbology, tap → list/detail works, responsiveness OK; (2) build + release. Follow-ups: add the
  remaining ZOS layers (`EPO`/`NV`/`jame` — a few lines each now: another `TileLayer` + chip), and
  a layer/legend picker once more than one is shown at once.
- **Discussion:** —
- **Shipped:** —

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
