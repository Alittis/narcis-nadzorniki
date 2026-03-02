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
- Backend/network failures: endpoint/config details unknown.
