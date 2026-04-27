# Operations Guide

## 1. Service Monitoring
- Not applicable as a VPS service from inspected repository data.
- For app validation:
```bash
flutter test
```

## 2. Logs
- Development runtime logs via Flutter tooling:
```bash
flutter run -d <device_id>
```

## 3. Restart Procedure
- Re-run application on target device/emulator via Flutter.

## 4. Update Procedure
```bash
git pull --ff-only
flutter pub get
flutter run -d <device_id>
```

## 5. Backup Strategy
- STATUS: UNKNOWN – REQUIRES CONFIRMATION.

## 6. Security Notes
- Mobile permissions and platform settings should be reviewed per release target.
- Secret handling strategy is not defined in inspected repository root.

## 7. Failure Scenarios
- Build failures: verify Flutter SDK and dependencies.
- Runtime permission issues: validate platform permission configuration.
- Backend/network failures: ORDS production base `https://narcis.gov.si/ords/narcis/`.
  - Probe production login endpoint (failure-path probes — no creds needed):
    ```bash
    bash tools/ords/test_auth_login.sh
    ```
  - Add success-path probe by exporting credentials:
    ```bash
    APP_AUTH_EMAIL=alexis.zrimec@gov.si \
    APP_AUTH_PASSWORD='...' \
        bash tools/ords/test_auth_login.sh
    ```
  - Expected on the success path: HTTP 200, JSON `{"authenticated":true,"user":"..."}`.
  - 401 with `{"authenticated":false,"message":"Neveljavni podatki za prijavo."}` for all failure modes (no enumeration leak between "no creds", "bad password", "not authorized").

## 8. Authentication (Production)
- Wire format: `X-Narcis-Auth: Basic <base64(email:password)>` over HTTPS to `https://narcis.gov.si/ords/narcis/app-auth/login` (see ARCHITECTURE.md §9.1 for why a custom header).
- Server gates by email lookup → `pkg_narcis_uporabniki.preveri_geslo` → `TERENSKA-BELEZNICA` function authorization.
- Client caches a PBKDF2-SHA256 hash of the password in `flutter_secure_storage` after a successful online login, enabling offline re-login for up to 14 days (see ARCHITECTURE §9bis for the full client model).
- Session is kept in memory (`AppState._currentUser`); app restart requires re-login. The offline cache makes that re-login work without network, up to the 14-day window.
- A definite server 401 wipes the offline cache. Network errors do NOT wipe — they fall through to offline.

## 9. Offline Authentication — Operational Caveat
Once offline login is enabled, an authorized user's cached credentials remain
valid for offline login until the configured max-offline window expires
(default: 14 days since `lastOnlineAuthAt`). Consequences for operators:

- Revoking a user's `TERENSKA-BELEZNICA` function on the server does NOT
  immediately lock them out of the app. They can continue logging in offline
  until their device next reaches the network OR until the offline window
  expires, whichever comes first. On the next online login attempt the server
  returns 401 and the client wipes the local cache.
- To shorten the revocation lag, lower the max-offline window in client config.
- For immediate lockout (e.g. compromised account), the only reliable path is
  changing the user's password server-side AND waiting for / forcing the
  device online; there is no remote-wipe channel in this app.
- First-time login is always online and gated by the server's
  `TERENSKA-BELEZNICA` check, so an unauthorized user can never establish an
  offline-capable cache in the first place.

## 10. Disturbance Sync — Operational Caveats
The disturbance CRUD endpoints (ARCHITECTURE.md §9.3) require the user's
plaintext password on every call (no bearer tokens yet). The Flutter client
keeps that password in memory only after a successful **online** login.
Operational consequences:

- A user who logged in offline (PBKDF2 cache hit) cannot sync queued
  records. Records continue to accumulate locally until the next online
  login, at which point `AppState.login` triggers `syncAll()` and the
  queue drains. This is not a bug — it's the deliberate trade for not
  storing plaintext passwords on disk.
- A 401 from any disturbance endpoint clears the in-memory password AND
  wipes the offline cache (same wipe path as a §9.1 401). The user must log
  in online again. Records remain queued.
- Edits and deletes made *while offline* are NOT queued — they apply only
  to the local row and never reach Oracle. Only creates queue. Operators
  who care about an edit being preserved must perform it while online.

### Recovery after app reinstall (sync icon UX)
After an app reinstall or `flutter clean` on a user's device, local storage
is wiped — but Oracle still has the records and photo BLOBs. Recovery is
automatic:

- On the next online login, `AppState.init()` runs `syncAll`, which calls
  `GET /disturbances/` and merges every server-side record back into the
  local store. Photos return as `{id, mimeType}` stubs — the BLOBs are
  fetched lazily when the user opens a record's detail view (saves
  bandwidth on cellular).
- The cloud-icon top-right of the map indicates the divergence state. While
  the user is offline-only or has just logged in for the first time, the
  icon shows an orange `cloud_download` glyph with a count badge meaning
  "remote has N records I haven't pulled yet". One tap on the icon (or the
  "Sinhroniziraj zdaj" tile in the Profile screen) drains both directions.
- On a brand-new device, type/observer junctions and proposed-type free
  text come back verbatim. Type display **names** are resolved against the
  bundled codebook in [lib/data/disturbance_types.dart](../lib/data/disturbance_types.dart);
  if the server has historical type codes that aren't in the codebook
  (e.g. an org-specific addition) the UI falls back to the raw code.

### Sync diagnostics (`[sync] …`)
The disturbance sync pipeline emits debug-print lines prefixed with `[sync]`
from four sites in [lib/state/app_state.dart](../lib/state/app_state.dart):

- `addRecord` — new record id, plus `isOnline` and `canSync` at save time.
- The `Connectivity.onConnectivityChanged` listener — raw result list, normalized
  result, and the resulting `isOnline` after the change.
- `syncAll` — entry/exit, count of `pendingSync==true` records to push, and the
  per-record push outcome.
- `_sendAndMarkSynced` — failures with the wrapped `RemoteApiException` (HTTP
  status code or underlying network cause).

To follow them on a connected device:
```bash
flutter run -d <device_id>
```
or, with the app already installed, tail logcat directly:
```bash
adb -s <device_id> logcat -v time '*:S' flutter:I | grep '\[sync\]'
```

Use these when investigating "I created a record offline and it never synced."
A representative healthy trace from a connectivity flip:
```
[sync] connectivity raw=[ConnectivityResult.none] normalized=ConnectivityResult.none (was=ConnectivityResult.mobile, isOnline=false)
[sync] addRecord <uuid> isOnline=false canSync=true
[sync] connectivity raw=[ConnectivityResult.mobile] normalized=ConnectivityResult.mobile (was=ConnectivityResult.none, isOnline=true)
[sync] syncAll() entry isOnline=true canSync=true isSyncing=false
[sync] pending records to push: 1
[sync]   push <uuid> → true
[sync] syncAll() exit
```
A 401 manifests as a `_sendAndMarkSynced ... FAILED: RemoteApiException(401): …`
line followed by `aborting after auth-clear` — at that point the in-memory
password is gone and the user must re-login online (see §10 caveats).

### Location diagnostics (`[gps] …`)
Same convention as `[sync]`, emitted from [lib/screens/home_screen.dart](../lib/screens/home_screen.dart):

- `[gps] one-shot fix: ok | null (no permission / no service)` — result of the
  startup `getCurrentPosition` call.
- `[gps] starting position stream` — confirms the continuous-update subscription
  was attached after the one-shot fix resolved (serialised so the two permission
  flows can't race).
- `[gps] tick lat=… lon=… acc=…m` — every position event from
  `Geolocator.getPositionStream` (5 m distance filter).
- `[gps] stream error: …` / `[gps] stream closed` — surfaces stream-side
  failures or unexpected termination.

Tail with:
```bash
adb -s <device_id> logcat -v time '*:S' flutter:I | grep '\[gps\]'
```

Use these to investigate "the dot doesn't move" reports — the typical
non-bug cause is the user being zoomed too far out for the per-tick metres
of movement to be visible (≈6.6 m/px at zoom 14).

### Photo storage operational notes
- Photos live in `TB_MOTNJE_FOTO.VSEBINA` as SECUREFILE BLOBs with
  `ENABLE STORAGE IN ROW` (small photos inline, large ones out-of-line).
  LOB-level `COMPRESS LOW` / `DEDUPLICATE` were considered but raise
  ORA-00439 on this instance (Advanced Compression option not licensed),
  and JPEGs are already compressed so it's a small loss. The client
  compresses to ~200–500 KB per photo before upload; the endpoint
  hard-caps at 10 MB and rejects unknown MIME types.
- Operators monitoring DB growth should track `SUM(VELIKOST)` in
  `TB_MOTNJE_FOTO`. There is currently no rate-limit on photo upload —
  STATUS: UNKNOWN – REQUIRES CONFIRMATION whether ORDS pool defaults are
  sufficient.
- A user removing a photo from a synced record only deletes server-side
  when they're online (same caveat as record edit/delete above). Photos
  removed from a not-yet-synced record never reach the server.
- After a deploy of `disturbance_endpoints.sql` and `disturbance_schema.sql`,
  smoke-test the photo lifecycle:
  ```
  APP_AUTH_EMAIL=... APP_AUTH_PASSWORD=... \
      bash tools/ords/test_disturbances.sh
  ```
  The script POSTs a 1×1 PNG, asserts duplicate-POST returns 200, GETs
  the bytes back with an image MIME, then DELETEs the photo and asserts
  the next GET returns 404.

### Probing the disturbance endpoints
Failure-path probes (no creds needed):
```bash
bash tools/ords/test_disturbances.sh
```
Full lifecycle (POST → POST again → PUT → DELETE → 404 checks):
```bash
APP_AUTH_EMAIL=alexis.zrimec@gov.si \
APP_AUTH_PASSWORD='...' \
    bash tools/ords/test_disturbances.sh
```
The full lifecycle creates and then deletes a record with a freshly
`uuidgen`'d ID, so it leaves no residue in `TB_MOTNJE` on success.

### Probing the walk-around endpoints
Same shape as the disturbance probes, against `narcis_walks`:
```bash
bash tools/ords/test_walks.sh
```
Full lifecycle (POST 3-point walk → idempotent re-POST → GET list →
GET points → PUT name+notes → DELETE → 404 checks):
```bash
APP_AUTH_EMAIL=alexis.zrimec@gov.si \
APP_AUTH_PASSWORD='...' \
    bash tools/ords/test_walks.sh
```
The full lifecycle creates and then deletes a walk (and its 3 points
via cascade) with a freshly `uuidgen`'d ID, so it leaves no residue in
`TB_OBHODI`/`TB_OBHODI_TOCKE` on success.

### Re-deploying to Oracle
The disturbance record endpoints (POST/PUT/DELETE) were deployed and
smoke-tested on 2026-04-26. The GET-list endpoint and photo CRUD endpoints
landed in source on 2026-04-26 and require a re-deploy of the schema and
endpoints scripts before the new sync-icon UX functions end-to-end. The
walk-around (obhod) schema and endpoints landed in source on 2026-04-27 and
require their own deploy plus a re-deploy of `disturbance_endpoints.sql`
(which now reads/writes the `obhodId` link).

For a fresh deploy or a re-deploy, run these SQL files in this order
against the same schema where `narcis_uporabniki` and `narcis_organizacije`
live:
```
tools/ords/disturbance_schema.sql           # disturbance tables (TB_MOTNJE, TB_MOTNJE_FOTO, ...)
tools/ords/disturbance_codebook_seed.sql    # global codebook (groups + types)
tools/ords/disturbance_auth_pkg.sql         # pkg_tb_auth helper package
tools/ords/walks_schema.sql                 # walk tables + ALTER TB_MOTNJE ADD OBHOD_ID
tools/ords/disturbance_endpoints.sql        # ORDS module narcis_disturbances (now includes obhodId)
tools/ords/walks_endpoints.sql              # ORDS module narcis_walks
```
All six are idempotent. `walks_schema.sql` must run AFTER `disturbance_schema.sql` because its ALTER adds the `OBHOD_ID` column + FK on `TB_MOTNJE`. Endpoint scripts can be deployed in either order relative to each other; both expect the schema files to be in place.

After deploying:
- `bash tools/ords/test_disturbances.sh` (with creds) for the disturbance lifecycle.
- `bash tools/ords/test_walks.sh` (with creds) for the walk lifecycle (POST 3-point walk → idempotent re-POST → GET list → GET points → PUT name+notes → DELETE → 404 checks).
