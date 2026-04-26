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
- Photo upload (BLOBs into `TB_MOTNJE_FOTO`) is OUT OF SCOPE for the current sync iteration. `Disturbance.photoPaths` is preserved on the device but stripped from the wire payload; photos do not reach Oracle.
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
| POST | `/` | Create (idempotent on `id`) | 201 created, 200 if same UUID already exists | 400 bad body, 401 |
| PUT | `:id` | Update fields + replace junctions | 200 | 400 bad body, 401, 404 (incl. cross-org) |
| DELETE | `:id` | Delete (junctions cascade) | 204 | 401, 404 |

- Auth: same `X-Narcis-Auth: Basic <base64(email:password)>` header as §9.1, on every call. `pkg_tb_auth.authenticate` raises `e_unauthorized` on any failure — handler returns 401 with `{"error":"unauthorized"}`. Same TERENSKA-BELEZNICA gate as login.
- `ORG_ID` is stamped server-side from `narcis_uporabniki.organizacija`; the client never sends it. PUT/DELETE silently 404 when the target row's org doesn't match the caller's — "not yours" is indistinguishable from "not found".
- Idempotency: POST with an already-known `motnja_id` is a no-op and returns 200 instead of 201. Lets the Flutter sync queue retry safely after a lost response.
- Wire payload (matches `Disturbance.toJson()` minus `pendingSync`/`photoPaths`/`createdAt`):
  ```json
  {
    "id": "<uuid>",
    "latitude": 45.79, "longitude": 14.36,
    "locationAccuracy": "natancna",
    "observedAt": "2026-04-25T12:00:00.000Z",
    "types": [{"groupCode": "1", "typeCode": "a"}],
    "description": "...",
    "observers": ["..."],
    "actionTaken": "brez",
    "proposedType": null
  }
  ```
- Smoke test: `bash tools/ords/test_disturbances.sh` (failure paths only without creds; full lifecycle when `APP_AUTH_EMAIL` + `APP_AUTH_PASSWORD` are exported).
- Status: schema designed and SQL written; **NOT YET DEPLOYED** to the production ORDS instance. STATUS: UNKNOWN – REQUIRES CONFIRMATION until `tools/ords/disturbance_schema.sql`, `disturbance_codebook_seed.sql`, `disturbance_auth_pkg.sql`, and `disturbance_endpoints.sql` are run against the live database in that order.

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
- `TB_MOTNJE` — main records. **PK is `MOTNJA_ID VARCHAR2(36)` — the client-generated UUID, NOT a server sequence**. Off Oracle convention but lets POST be naturally idempotent on retry without a separate dedupe column. `ORG_ID` is stamped server-side from the authenticated user's `narcis_uporabniki.organizacija`. `OPIS CLOB` for the long description; lat/lon as `NUMBER(10,7)`; `CAS_OPAZOVANJA TIMESTAMP`. Audit columns: `USTVARJEN_OD/USTVARJEN`, `SPREMENJEN_OD/SPREMENJEN`. Indexes on `(ORG_ID, CAS_OPAZOVANJA DESC)` and `USTVARJEN_OD`.
- `TB_MOTNJE_TIPI_DOGODKA` — junction (record × selected types). Composite PK `(MOTNJA_ID, SKUPINA_KODA, TIP_KODA)`. **Intentionally NOT a FK to `TB_SIF_MOTNJE_TIPI`** so historical records keep their type codes even if a codebook row is later renamed or deactivated.
- `TB_MOTNJE_OPAZOVALCI` — junction (record × observers). Composite PK `(MOTNJA_ID, IME_OPAZOVALCA)`. `IME_OPAZOVALCA` is the free-text name as the user typed it on the phone; `UPORABNIK_ID` is a nullable FK to `narcis_uporabniki.id` for resolution to a system user (resolution logic is a follow-up — currently always NULL).

Cascading delete: `TB_MOTNJE → TB_MOTNJE_TIPI_DOGODKA, TB_MOTNJE_OPAZOVALCI` are `ON DELETE CASCADE`.

**Photo storage** (`TB_MOTNJE_FOTO` with `BLOB`) is reserved for a follow-up iteration and is NOT created by the schema script.

## 13. Sync Model (Flutter `RemoteApi` + `AppState`)
[lib/data/remote_api.dart](../lib/data/remote_api.dart) talks to §9.3. [lib/state/app_state.dart](../lib/state/app_state.dart) owns the queue.

**Session credentials.** The disturbance endpoints re-authenticate every call via `X-Narcis-Auth: Basic <base64(email:password)>`. The plaintext password is required, but `AuthService` only stores a one-way PBKDF2 hash on disk (see §9bis). Resolution: `AppState` keeps the plaintext password **in memory only**, set on a successful **online** login (`AuthResult.wasOffline == false`), cleared on logout, on app exit, and on a sync 401. Never written to disk. `AppState.canSync` is true iff `_currentUser != null && _sessionPassword != null`.

**Queue lifecycle.**
1. `addRecord` writes the local row with `pendingSync = !(isOnline && canSync)`. If we have a sync path, it tries to push immediately via `_sendAndMarkSynced`.
2. On a successful POST (201 or 200 idempotent), `pendingSync` flips to false.
3. On `RemoteApiException` with `isUnauthorized`: clear `_sessionPassword`, wipe the offline cache (`_authService.clearCache()`), leave the row pending. Subsequent sync attempts no-op until the user logs in online again.
4. On `RemoteApiException` with `isNetwork` or 5xx: leave the row pending. Connectivity changes (`Connectivity.onConnectivityChanged`) re-trigger `syncPending`.
5. `syncPending` short-circuits when `!isOnline || _isSyncing || !canSync`.

**Implications.**
- Records created during an *offline* login session stay queued until the next *online* login. Records created during an online session are pushed immediately (or queued briefly across a connectivity blip).
- Update / delete are NOT queued: they only fire when online + `canSync`. Edits made offline persist locally but don't reach Oracle. (Tracked as a follow-up; the create queue is the priority since it's the field-data path.)
- Photo uploads do not happen yet (see §8).

## Documentation Authority
The /project directory is the single source of truth for:
- Architecture
- Deployment
- Operational procedures

All structural changes must update these documents.
