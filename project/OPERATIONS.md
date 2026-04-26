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
  login, at which point `AppState.login` triggers `syncPending()` and the
  queue drains. This is not a bug — it's the deliberate trade for not
  storing plaintext passwords on disk.
- A 401 from any disturbance endpoint clears the in-memory password AND
  wipes the offline cache (same wipe path as a §9.1 401). The user must log
  in online again. Records remain queued.
- Edits and deletes made *while offline* are NOT queued — they apply only
  to the local row and never reach Oracle. Only creates queue. Operators
  who care about an edit being preserved must perform it while online.

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

### First-time deployment to Oracle
The disturbance endpoints are **not yet deployed**. To deploy, run these
SQL files in this order against the same schema where `narcis_uporabniki`
and `narcis_organizacije` live:
```
tools/ords/disturbance_schema.sql           # tables, indexes, sequence
tools/ords/disturbance_codebook_seed.sql    # global codebook (groups + types)
tools/ords/disturbance_auth_pkg.sql         # pkg_tb_auth helper package
tools/ords/disturbance_endpoints.sql        # ORDS module narcis_disturbances
```
All four are idempotent. After deploying, run `bash tools/ords/test_disturbances.sh` (with creds) for the lifecycle smoke test.
