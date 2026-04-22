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
- Backend/network failures: ORDS base `https://storitve.igea.si/narcis/ords/narcis/`.
  - Probe auth endpoint:
    ```bash
    curl -sS -i -H "username: alexis.zrimec@gov.si" \
      "https://storitve.igea.si/narcis/ords/narcis/test/auth"
    ```
  - Expected: HTTP 200, JSON `{"authenticated":true,...}`.
  - 401 for any other email means the endpoint is up and rejecting correctly.

## 8. Authentication (Test Phase)
- Only `alexis.zrimec@gov.si` is accepted by `/test/auth`; password is ignored.
- Session is kept in memory (`AppState._currentUser`); app restart requires re-login.
- Must be replaced before production (see ARCHITECTURE §8 Known Unknowns).
