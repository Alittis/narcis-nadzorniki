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
