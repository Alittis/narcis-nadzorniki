# Project Architecture

## 1. Overview
`narcis-nadzorniki` is a Flutter application repository targeting mobile (Android/iOS) and additional Flutter platforms (`web`, `linux`, `macos`, `windows` scaffolding present).

## 2. System Components
- Frontend
  - Flutter UI in `lib/`.
- Backend
  - Oracle APEX / ORDS declarative RESTful Services hosted at `https://storitve.igea.si/narcis/ords/narcis/`.
  - Module `narcis` (base path `narcis/`).
- Database
  - Oracle database behind APEX/ORDS (managed externally).
- External Services
  - ORDS REST endpoints (see §9 below).
  - Online basemap tile providers (see §10 below).
- Infrastructure Components
  - Flutter toolchain build system.

## 3. Repository Structure
- `lib/` — application source
- `android/`, `ios/` — mobile platform projects
- `web/`, `linux/`, `macos/`, `windows/` — platform targets
- `test/` — Flutter tests
- `assets/legacy/` — bundled read-only historical datasets (see §11)
- `tools/` — one-off import/conversion scripts (Python)
- `pubspec.yaml` — dependencies and metadata

## 4. Runtime Architecture
- App runs as compiled Flutter client on target device/platform.
- No server/runtime process manager definition detected in repository root.

## 5. Environment Strategy
- Development: Flutter local run (`flutter run`).
- Staging: STATUS: UNKNOWN – REQUIRES CONFIRMATION.
- Production: app store/device distribution strategy not defined in inspected files.

## 6. Dependency Graph
- Flutter SDK
- Dart packages from `pubspec.yaml`

## 7. Architectural Decisions (Initial)
- Flutter multi-platform project structure.
- Client-first architecture in current repository.

## 8. Known Unknowns
- Login handler still carries debug instrumentation (`narcis_auth_debug` table + per-request env dump). A56 real-device validation passed cleanly on 2026-04-25; credentials are now redacted in the dump (auth-bearing headers logged as `<REDACTED len=NN>`, `auth_hdr_prefix` reduced to `Basic ` for the conformant case), so the instrumentation is safe to keep on while we widen device/carrier coverage. Cleanup checklist, to run once we're satisfied with that coverage:
  1. Strip the `OWA.cgi_var_*` snapshot block and the three dead `HTTP_*` fallbacks from `tools/ords/auth_login.sql`; keep only `OWA_UTIL.get_cgi_env('X-NARCIS-AUTH')`.
  2. Strip the `narcis_auth_debug` INSERT block from the handler.
  3. Redeploy the handler.
  4. `DROP TABLE narcis_auth_debug PURGE;`
  5. Delete `tools/ords/auth_debug_table.sql`.
- No rate limiting / account lockout on the login endpoint — STATUS: UNKNOWN – REQUIRES CONFIRMATION whether `pkg_narcis_uporabniki.preveri_geslo` enforces this internally.
- No session/bearer token mechanism yet; the disturbance CRUD endpoints (§9.3) re-validate `X-Narcis-Auth: Basic` on every call. This is intentional for now; bearer-token migration is a follow-up. Implication: `RemoteApi` calls re-run `pkg_narcis_uporabniki.preveri_geslo` server-side per record synced.
- Codebook fetch endpoint (PDF §6.c.ii — "ob vsakem zagonu aplikacije naj se na telefonu posodobi seznam tipov motenj") is NOT YET IMPLEMENTED. Until it is, `lib/data/disturbance_types.dart` and `tools/ords/disturbance_codebook_seed.sql` are dual-maintained: any change to the Dart codebook must be mirrored in the seed script. Per-org codebook additions (`TB_SIF_MOTNJE_TIPI.ORG_ID` non-null) are not yet visible to the client.
- Offline updates and offline deletes do not queue: `AppState.updateRecord` / `deleteRecord` only push to ORDS when `isOnline && canSync`. Edits made while offline persist locally but never reach the server. Tracked as a separate follow-up to the offline-create queue.
- Release pipeline/signing/distribution process.
- CI/CD workflow (none detected in repository root scope).

## 9. Backend Endpoints

### 9.1 `GET https://narcis.gov.si/ords/narcis/app-auth/login` (production login)
- Auth: `X-Narcis-Auth: Basic <base64(email:password)>` over HTTPS only. (Custom header, not the standard `Authorization` — see note below.)
- ORDS module: `narcis_app_auth`, base path `app-auth/`, template `login`.
- Server logic: email → `app_user` lookup (case-insensitive, whitespace-tolerant), then `pkg_narcis_uporabniki.preveri_geslo`, then `pkg_narcis_authorization.has_function_by_id('TERENSKA-BELEZNICA', app_user)`. Any failure → 401 with a single generic message (no enumeration).
- 200: `{"authenticated":true,"user":"<email>"}`
- 401: `{"authenticated":false,"message":"Neveljavni podatki za prijavo."}`
- CORS: inherited from ORDS pool (`Access-Control-Allow-Origin: *`, confirmed live).
- Source: [tools/ords/auth_login.sql](../tools/ords/auth_login.sql).
- Status: deployed and smoke-tested (2026-04-25). All four probes pass: no header → 401, bad creds → 401, empty password → 401, valid creds → 200 with `{"authenticated":true,"user":"..."}`. A56 real-device validation also passed on the same date. Currently still carries debug instrumentation (`narcis_auth_debug` table + per-request env dump); credentials redacted as of 2026-04-25, see §8 for cleanup checklist gating.
- Why a custom header instead of the standard `Authorization`: this ORDS instance consumes `Authorization: Basic` upstream of the handler PL/SQL (verified 2026-04-25 via debug logging — `OWA_UTIL.get_cgi_env('HTTP_AUTHORIZATION')` returned NULL on every request, even when the client sent a valid Basic header). A custom `X-Narcis-Auth` header bypasses ORDS's auth filter while preserving the same base64 encoding scheme.
- Quirk: ORDS exposes this custom header under its raw HTTP name (`x-narcis-auth`), NOT under the canonical CGI form `HTTP_X_NARCIS_AUTH`. Standard headers get both forms; custom headers only get the raw form. The handler reads it via `OWA_UTIL.get_cgi_env('X-NARCIS-AUTH')` (the function is case-insensitive). Verified by enumerating `OWA.cgi_var_name(i)` / `cgi_var_val(i)` on a live request.
- Known cosmetic gap: response `Content-Type` header comes back as `text/html;charset=utf-8` instead of `application/json`. The `:content_type` HEADER OUT bind doesn't appear to take effect in this ORDS configuration. The body itself is valid JSON and `jsonDecode` parses it fine, so this is non-blocking.

### 9.2 `GET /narcis/ords/narcis/test/auth` (legacy stub, retired)
- Headers: `username: <email>`
- 200 with `{"authenticated":true,"user":"<email>"}` if header equals `alexis.zrimec@gov.si`
- 401 with `{"authenticated":false,"message":"Invalid credentials"}` otherwise
- CORS: `Access-Control-Allow-Origin: *`
- Status: superseded by §9.1 as of the Flutter cutover (2026-04-25). The Flutter client no longer calls this endpoint. Stub may be removed from ORDS at any time.

### 9.3 Disturbance CRUD — `https://narcis.gov.si/ords/narcis/disturbances/`
ORDS module: `narcis_disturbances`, base path `disturbances/`. Source: [tools/ords/disturbance_endpoints.sql](../tools/ords/disturbance_endpoints.sql). Auth helper: [tools/ords/disturbance_auth_pkg.sql](../tools/ords/disturbance_auth_pkg.sql) (`pkg_tb_auth`). Schema: [tools/ords/disturbance_schema.sql](../tools/ords/disturbance_schema.sql). Codebook seed: [tools/ords/disturbance_codebook_seed.sql](../tools/ords/disturbance_codebook_seed.sql).

| Method | Pattern | Purpose | Success | Failure |
|---|---|---|---|---|
| GET | `/` | List caller's records (with photo metadata) | 200 `{records:[...]}` | 401, 500 |
| POST | `/` | Create (idempotent on `id`) | 201 created, 200 if same UUID already exists | 400 bad body, 401 |
| PUT | `:id` | Update fields + replace junctions (photos untouched) | 200 | 400 bad body, 401, 404 (incl. cross-org) |
| DELETE | `:id` | Delete (junctions + photos cascade) | 204 | 401, 404 |
| POST | `:id/photos/:photoId` | Upload binary photo (idempotent on `photoId`) | 201 created, 200 already exists | 400 empty, 401, 404 record, 413 too large, 415 bad MIME |
| GET | `:id/photos/:photoId` | Download photo BLOB | 200 with image MIME | 401, 404 |
| DELETE | `:id/photos/:photoId` | Delete photo | 204 | 401, 404 |

- Auth: same `X-Narcis-Auth: Basic <base64(email:password)>` header as §9.1, on every call. `pkg_tb_auth.authenticate` raises `e_unauthorized` on any failure — handler returns 401 with `{"error":"unauthorized"}`. Same TERENSKA-BELEZNICA gate as login.
- `ORG_ID` is stamped server-side from `narcis_uporabniki.organizacija`; the client never sends it. PUT/DELETE/photo-* silently 404 when the target row's org doesn't match the caller's — "not yours" is indistinguishable from "not found".
- Idempotency: POST with an already-known `motnja_id` is a no-op and returns 200 instead of 201. Same goes for photo upload on a known `photoId`. Lets the Flutter sync queue retry safely after a lost response.
- GET `/` response shape: `{"records":[{...record fields...,"photos":[{"id":"<uuid>","mimeType":"image/jpeg"},...]}]}`. Photo BLOBs are NOT inlined — the client lazy-fetches each one via the per-photo GET when the user opens the detail view.
- Photo upload limits: `Content-Type` must be `image/jpeg`, `image/png`, `image/webp`, or `image/heic` (415 otherwise). Body cap is 10 MB (413 otherwise) — the client compresses to ~200–500 KB via `image_picker` `maxWidth=1600, imageQuality=85` so the cap is a defense against accidental original-resolution uploads.
- Wire payload for record CRUD (matches `Disturbance.toJson()` minus `pendingSync`/`photos`/`createdAt`). Note: `locationAccuracy` and `actionTaken` carry the **Slovenian display labels** verbatim from the Flutter dropdowns (`form_screen.dart`), not normalized codes - the `CK_TB_MOTNJE_LOC` constraint and the column values match those labels.
  ```json
  {
    "id": "<uuid>",
    "latitude": 45.79, "longitude": 14.36,
    "locationAccuracy": "Natančna",
    "observedAt": "2026-04-25T12:00:00.000Z",
    "types": [{"groupCode": "1", "typeCode": "a"}],
    "description": "...",
    "observers": ["..."],
    "actionTaken": "Brez ukrepanja",
    "proposedType": null
  }
  ```
  Allowed `locationAccuracy` values: `Natančna`, `Približna`.
  Allowed `actionTaken` values: `Brez ukrepanja`, `Ustno opozorilo`, `Pisno opozorilo`, `Drugo` (currently no CHECK constraint, just a free `VARCHAR2(50)`).
- Each handler has a top-level `WHEN OTHERS` guard that ROLLBACKs and returns HTTP 500 with `{"error":"server_error","sqlcode":...,"sqlerrm":"..."}`. Without it, an unhandled PL/SQL exception in this ORDS instance returns 200 with no body - which the Flutter client would mistake for a successful sync (a real silent-failure bug bit us on 2026-04-26 with a `CK_TB_MOTNJE_LOC` violation).
- Smoke test: `bash tools/ords/test_disturbances.sh` (failure paths only without creds; full lifecycle including photo upload/download/delete when `APP_AUTH_EMAIL` + `APP_AUTH_PASSWORD` are exported).
- Status: deployed and smoke-tested 2026-04-26. GET-list, photo CRUD, and `TB_MOTNJE_FOTO` all landed and verified — full 17-probe lifecycle (incl. photo upload/duplicate-idempotency/download/delete/404-after-delete) passes against production.
- Known cosmetic quirk on the photo GET: response `Content-Type` comes back as `image/jpeg` regardless of what was stored in `MIME_TYPE`, because `WPG_DOCLOAD.download_file` overrides the `:content_type` HEADER OUT bind (similar pattern to the §9.1 quirk on the auth endpoint). The actual bytes are correct, and the client identifies the format from the on-disk file extension when rendering, so this is non-blocking. Investigate by switching to `OWA_UTIL.mime_header` before `WPG_DOCLOAD.download_file` if/when we start ingesting non-JPEG photos and need accurate MIME on the wire.

## 9bis. Client Authentication (Flutter)

Implemented in [lib/services/auth_service.dart](../lib/services/auth_service.dart), driven by [lib/state/app_state.dart](../lib/state/app_state.dart).

**Online path** (when `AppState.isOnline`):
1. Build `X-Narcis-Auth: Basic <base64(email:password)>` and GET §9.1.
2. On HTTP 200 with `authenticated:true`: cache credentials (see schema below) and return success.
3. On HTTP 401: **wipe** the offline cache and return failure. This propagates server-side TERENSKA-BELEZNICA revocation to the device on the next online attempt.
4. On network error / timeout / 5xx: fall through to the offline path.

**Offline path** (used as primary when `AppState.isOnline` is false, or as fallback after a network error):
1. Read cache. Mismatched email or empty cache → fail with "no saved credentials".
2. Algo-version mismatch → fail with "saved credentials outdated, please log in online" (forces a re-cache under the current scheme).
3. `now() - lastOnlineAt > maxOfflineWindow (14 days)` → fail with "offline window expired".
4. Recompute `PBKDF2-HMAC-SHA256(password, cache.salt, 100000, 32)` and compare against `cache.hash` in constant time. Mismatch → fail.
5. Otherwise success with `wasOffline = true`.

**Offline cache schema** (in `flutter_secure_storage` — Keychain on iOS, EncryptedSharedPreferences/Keystore on Android):

| Key | Value |
|---|---|
| `narcis_auth_email` | normalized lowercase email |
| `narcis_auth_salt_b64` | 32 random bytes, base64 |
| `narcis_auth_hash_b64` | PBKDF2-HMAC-SHA256(password, salt, 100000, 32 bytes), base64 |
| `narcis_auth_last_online_at` | UTC ISO-8601 timestamp of the last successful online login |
| `narcis_auth_algo` | `pbkdf2_sha256_100k_v1` (version tag enabling future migrations) |

The email is written **last** so that a partial-write crash leaves the cache effectively empty rather than half-populated.

**Threat model**: PBKDF2 here is NOT defending a server-side password DB; it slows down a forensic extraction of the device's secure storage. 100k iterations is sufficient for that purpose. The `algo` version tag lets us bump iterations later without breaking existing devices (they'll be forced online once and re-cached under the new scheme).

**Session persistence**: in-memory only (`AppState._currentUser`). App restart requires re-login, but the offline cache makes that re-login work without network. This is intentional — sticky sessions across restarts is a separate UX decision not yet made.

**First-time login is always online**: cache is empty until the first online success, so an unauthorized user can never establish an offline-capable cache. See OPERATIONS.md §9 for the operator-facing implications of the offline window.

## 10. Basemap Tile Providers
Online basemap tiles are requested directly from public tile servers via `flutter_map` `TileLayer`s. Two modes, switchable at runtime by the user:

- `osm` (default): OpenStreetMap standard tiles
  - `https://tile.openstreetmap.org/{z}/{x}/{y}.png`
  - Max zoom 19. Subject to the OpenStreetMap Tile Usage Policy.
- `satellite`: Esri ArcGIS Online (two stacked layers)
  - Imagery: `https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}`
  - Labels overlay: `https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}`
  - Max zoom 19. Subject to Esri World Imagery terms of use.

Shared implementation: `lib/widgets/basemap.dart` (`BasemapMode`, `basemapTileLayers`, `BasemapToggleButton`). Used by `home_screen.dart` and `location_picker_screen.dart`. Additional overlays (disturbance markers, etc.) are layered on top in each screen's `FlutterMap.children` after the basemap layers.

`userAgentPackageName` sent with tile requests: `si.narcis.nadzorniki`.

No API key is required for either provider at this time. STATUS: UNKNOWN – REQUIRES CONFIRMATION whether Esri terms permit production/commercial use of this app without licensing.

## 11. Legacy Data (Read-Only Historical Context)
Historical disturbance records from another app (Notranjski regijski park's WordPress Formidable form at `nadzor.notranjski-park.si`) are bundled as a read-only JSON asset so observers can see prior field activity on the map.

- Asset path: `assets/legacy/notranjski_park_2025.json` (703 records, ~408 KB, covers Mar–Aug 2025).
- Model: [lib/models/legacy_disturbance.dart](../lib/models/legacy_disturbance.dart).
- Loader: [lib/data/legacy_records.dart](../lib/data/legacy_records.dart) — loads once at `AppState.init()`.
- Display: small purple dots on `HomeScreen` map; tap opens [lib/screens/legacy_detail_screen.dart](../lib/screens/legacy_detail_screen.dart). Toggled via `AppState.showLegacy` in the settings sheet.
- Category values are preserved verbatim from the source (free-text, typos included, not mapped to the app's codebook). The detail view renders them grouped by our group names.
- Photo URLs point to the original WordPress uploads at `https://nadzor.notranjski-park.si/wp-content/uploads/...` and require online access to render.
- Source CSV is NOT committed. To regenerate the asset from a new CSV export:
  ```
  python3 tools/import_notranjski_csv.py \
    --input "/path/to/formidable_entries.csv" \
    --output assets/legacy/notranjski_park_2025.json
  ```
  Dependencies: `openlocationcode` (for Plus Code → lat/lon decoding on rows without explicit coordinates). Reference anchor: Cerknica (45.79, 14.36).
- Dropped on import: rows with `Entry Status=3` (drafts), rows with no category selected, rows with no resolvable coordinates.
- These records are explicitly **not** writable from the app and do not sync to ORDS. They exist only to give observers map context for work already done by the other app.

## 12. Disturbance Schema (Oracle, prefix `TB_`)
Defined in [tools/ords/disturbance_schema.sql](../tools/ords/disturbance_schema.sql). All tables prefixed `TB_` for "Terenska beležka" so the app's tables are easy to distinguish from other tables in the shared `narcis` schema.

**Tables:**
- `TB_SIF_MOTNJE_SKUPINE` — group codebook. PK `SKUPINA_KODA VARCHAR2(2)`. Universal (no per-org variation by design — confirmed 2026-04-25).
- `TB_SIF_MOTNJE_TIPI` — type codebook. Synthetic PK `TIP_ID NUMBER`. Unique on `(SKUPINA_KODA, TIP_KODA, NVL(ORG_ID, 0))` — same `(group, type)` pair can exist once globally (`ORG_ID NULL`) and once per organization. Per-org additions live alongside the global codebook.
- `TB_MOTNJE` — main records. **PK is `MOTNJA_ID VARCHAR2(36)` — the client-generated UUID, NOT a server sequence**. Off Oracle convention but lets POST be naturally idempotent on retry without a separate dedupe column. `ORG_ID` is stamped server-side from the authenticated user's `narcis_uporabniki.organizacija`. `OPIS CLOB` for the long description; lat/lon as `NUMBER(10,7)`; `CAS_OPAZOVANJA TIMESTAMP`. `NATANCNOST_LOK VARCHAR2(20)` constrained to `'Natančna'` / `'Približna'` (verbatim Slovenian labels from the Flutter form). `UKREPANJE VARCHAR2(50)` is unconstrained free text; expected values are the four dropdown labels (`Brez ukrepanja`, `Ustno opozorilo`, `Pisno opozorilo`, `Drugo`). Audit columns: `USTVARJEN_OD/USTVARJEN`, `SPREMENJEN_OD/SPREMENJEN`. Indexes on `(ORG_ID, CAS_OPAZOVANJA DESC)` and `USTVARJEN_OD`.
- `TB_MOTNJE_TIPI_DOGODKA` — junction (record × selected types). Composite PK `(MOTNJA_ID, SKUPINA_KODA, TIP_KODA)`. **Intentionally NOT a FK to `TB_SIF_MOTNJE_TIPI`** so historical records keep their type codes even if a codebook row is later renamed or deactivated.
- `TB_MOTNJE_OPAZOVALCI` — junction (record × observers). Composite PK `(MOTNJA_ID, IME_OPAZOVALCA)`. `IME_OPAZOVALCA` is the free-text name as the user typed it on the phone; `UPORABNIK_ID` is a nullable FK to `narcis_uporabniki.id` for resolution to a system user (resolution logic is a follow-up — currently always NULL).
- `TB_MOTNJE_FOTO` — photos. **PK `FOTO_ID VARCHAR2(36)` is a client-generated UUID**, same pattern as `TB_MOTNJE.MOTNJA_ID` — lets the photo upload endpoint be naturally idempotent on retry. `VSEBINA BLOB` stored as SECUREFILE with `ENABLE STORAGE IN ROW` (small photos inline; large ones offline). `MIME_TYPE` constrained to `image/jpeg|png|webp|heic`. `VELIKOST` is the byte length, used by clients/operators to budget storage; CHECK ensures it's positive. `USTVARJEN_OD` is the uploader's email. **Note:** SECUREFILE `COMPRESS LOW` + `DEDUPLICATE` would be ideal but require the Advanced Compression option license (raises ORA-00439 on this instance); JPEGs are already compressed so plain SECUREFILE is the right default until/unless that license is added.

Cascading delete: `TB_MOTNJE → TB_MOTNJE_TIPI_DOGODKA, TB_MOTNJE_OPAZOVALCI, TB_MOTNJE_FOTO` are all `ON DELETE CASCADE`.

## 13. Sync Model (Flutter `RemoteApi` + `AppState`)
[lib/data/remote_api.dart](../lib/data/remote_api.dart) talks to §9.3. [lib/state/app_state.dart](../lib/state/app_state.dart) owns the queue.

**Session credentials.** The disturbance endpoints re-authenticate every call via `X-Narcis-Auth: Basic <base64(email:password)>`. The plaintext password is required, but `AuthService` only stores a one-way PBKDF2 hash on disk (see §9bis). Resolution: `AppState` keeps the plaintext password **in memory only**, set on a successful **online** login (`AuthResult.wasOffline == false`), cleared on logout, on app exit, and on a sync 401. Never written to disk. `AppState.canSync` is true iff `_currentUser != null && _sessionPassword != null`.

**`syncAll` (the sync icon's tap-target).** Single entry point that runs three phases under one `_isSyncing` flag:
1. **Push pending records.** Drain `_records.where(pendingSync)` via POST `/disturbances/`. Server's idempotent-on-UUID semantics mean retries are safe.
2. **Drain pending photo uploads.** For every record with a `pendingUpload` photo, read the local file and POST it to `/disturbances/:id/photos/:photoId`. Photos can't be uploaded before the parent record exists, hence the strict ordering.
3. **Pull remote list and merge.** GET `/disturbances/`, build a `_lastRemoteIds` set, and merge each `RemoteDisturbance` into `_records`. Local-only `pendingSync` records are kept; for IDs known to both sides, server wins on the record fields and we preserve any cached photo `localPath`s. Photos return without `localPath` and are lazy-fetched via `ensurePhotoCached` when the user opens the detail screen.

**Divergence indicator.** The icon at [home_screen.dart:520](lib/screens/home_screen.dart:520) reads three numbers off `AppState`:
- `pendingPushCount` — records with `pendingSync` OR any `pendingUpload` photo.
- `missingLocalCount` — `|_lastRemoteIds \ localIds|` (zero until first successful pull).
- `pendingCount` — sum, shown as the badge.
Three visual states: green `cloud_done` when in sync, orange `cloud_upload` when there's anything to push, orange `cloud_download` when only the remote has more. Grey `cloud_off` when offline.

**Photo lifecycle.**
1. Form picks a photo via `image_picker` (`maxWidth=1600`, `quality=85`) → temp path.
2. `addRecord` calls `PhotoStorage.savePicked` to copy the file to `<docs>/disturbance_photos/<motnja_id>/<foto_id>.<ext>` so it survives across app restarts. The new `DisturbancePhoto` lands with `pendingUpload=true`.
3. Next `syncAll` reads the file and POSTs the bytes. Success flips `pendingUpload=false`.
4. `ensurePhotoCached` (called from `DetailScreen.initState`) downloads any photo with no `localPath` and writes it under the same canonical layout.

**Implications.**
- Records created during an *offline* login session stay queued until the next *online* login. Records created during an online session are pushed immediately (or queued briefly across a connectivity blip).
- After a fresh install + online login, `init()` runs `syncAll`, which pulls all of the user's records from Oracle. Photos download lazily on first detail view.
- Update / delete are NOT queued: they only fire when online + `canSync`. Edits made offline persist locally but don't reach Oracle. (Tracked as a follow-up; the create queue is the priority since it's the field-data path.)
- Photo deletes also fire only online; offline removal in the form doesn't queue. Photos that exist on the server but not locally still render in the detail view as a placeholder + lazy-fetch.

## 14. New-Record Entry Flow (Client UI)
The red "+" FAB on `HomeScreen` (lib/screens/home_screen.dart) is a speed dial. Tapping it expands two mini-FABs above it: **Foto** (camera) and **Šifrant** (codebook). The single-tap-to-form path is intentionally gone — observers in the field have one of two intents and the entry point reflects that.

- **GPS lock at intent time.** Tapping "+" snapshots `_userLocation` into `_capturedLocation` immediately and kicks off a fresh `LocationService.getCurrentLocation()` in the background. Whichever arrives first becomes the location passed to `FormScreen`. This prevents drift if the camera or type-selection step takes a while; the location stamped on the record is where the user *was* when they declared intent, not where they happened to be when they finally hit Shrani.
- **Photo flow.** `_startPhotoFlow` launches `image_picker` with `ImageSource.camera`. On `PlatformException(camera_access_denied)` the user gets a snackbar and stays on home (no gallery fallback — fresh GPS exif matters). On success, `FormScreen` opens with `initialPhotoPath` and the locked location prefilled.
- **Codebook flow.** `_startCodebookFlow` pushes the existing `TypeSelectionScreen` with empty initial selections. An empty / cancelled return drops the user back on home with no record. Non-empty selections open `FormScreen` with `initialTypes` and the locked location prefilled.
- **Form validation unchanged.** The form still requires location + at least one type before Shrani, so the photo flow still forces a type pick (just inside the form). A future "quick save" sheet that bypasses the form when both photo and types are set is deferred — see "Open optimizations" below.

Open optimizations (not in scope yet):
- Quick-save bottom sheet for the trivial case (photo + 1 type + auto-location), skipping the full form.
- Photo flow could chain into the type-picker before landing on the form, so the form lands prefilled in both paths.

## Documentation Authority
The /project directory is the single source of truth for:
- Architecture
- Deployment
- Operational procedures

All structural changes must update these documents.
