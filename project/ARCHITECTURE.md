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
- Login handler still carries debug instrumentation (`narcis_auth_debug` table + per-request env dump). DO NOT REMOVE until the Flutter cutover has run against real-device / real-network traffic and confirmed clean — the env dump is our only window into how mobile carriers / proxies might mangle the X-Narcis-Auth header. Cleanup checklist when the time comes:
  1. Strip the `OWA.cgi_var_*` snapshot block and the three dead `HTTP_*` fallbacks from `tools/ords/auth_login.sql`; keep only `OWA_UTIL.get_cgi_env('X-NARCIS-AUTH')`.
  2. Strip the `narcis_auth_debug` INSERT block from the handler.
  3. Redeploy the handler.
  4. `DROP TABLE narcis_auth_debug PURGE;`
  5. Delete `tools/ords/auth_debug_table.sql`.
- No rate limiting / account lockout on the login endpoint — STATUS: UNKNOWN – REQUIRES CONFIRMATION whether `pkg_narcis_uporabniki.preveri_geslo` enforces this internally.
- No session/bearer token mechanism yet; subsequent CRUD endpoints will need one (re-sending Basic creds on every call is the wrong long-term answer).
- Disturbance CRUD endpoints on ORDS — not yet implemented; `RemoteApi` is a stub with delays only.
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
- Status: deployed and smoke-tested (2026-04-25). All four probes pass: no header → 401, bad creds → 401, empty password → 401, valid creds → 200 with `{"authenticated":true,"user":"..."}`. Currently still carries debug instrumentation (`narcis_auth_debug` table + per-request env dump); to be removed once the Flutter client cutover lands.
- Why a custom header instead of the standard `Authorization`: this ORDS instance consumes `Authorization: Basic` upstream of the handler PL/SQL (verified 2026-04-25 via debug logging — `OWA_UTIL.get_cgi_env('HTTP_AUTHORIZATION')` returned NULL on every request, even when the client sent a valid Basic header). A custom `X-Narcis-Auth` header bypasses ORDS's auth filter while preserving the same base64 encoding scheme.
- Quirk: ORDS exposes this custom header under its raw HTTP name (`x-narcis-auth`), NOT under the canonical CGI form `HTTP_X_NARCIS_AUTH`. Standard headers get both forms; custom headers only get the raw form. The handler reads it via `OWA_UTIL.get_cgi_env('X-NARCIS-AUTH')` (the function is case-insensitive). Verified by enumerating `OWA.cgi_var_name(i)` / `cgi_var_val(i)` on a live request.
- Known cosmetic gap: response `Content-Type` header comes back as `text/html;charset=utf-8` instead of `application/json`. The `:content_type` HEADER OUT bind doesn't appear to take effect in this ORDS configuration. The body itself is valid JSON and `jsonDecode` parses it fine, so this is non-blocking.

### 9.2 `GET /narcis/ords/narcis/test/auth` (legacy stub, retired)
- Headers: `username: <email>`
- 200 with `{"authenticated":true,"user":"<email>"}` if header equals `alexis.zrimec@gov.si`
- 401 with `{"authenticated":false,"message":"Invalid credentials"}` otherwise
- CORS: `Access-Control-Allow-Origin: *`
- Status: superseded by §9.1 as of the Flutter cutover (2026-04-25). The Flutter client no longer calls this endpoint. Stub may be removed from ORDS at any time.

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

## Documentation Authority
The /project directory is the single source of truth for:
- Architecture
- Deployment
- Operational procedures

All structural changes must update these documents.
