# Deployment Documentation

## 1. Target Environment
This is a Flutter client application. There is no VPS/server runtime in this repository — the backend (ORDS / Oracle / NarcIS) is operated by ARSO (see ARCHITECTURE §9).

Distribution channels:
- **Android**: Google Play Console, app `si.terenska.beleznica`, internal testing track (Alittis as Play publisher).
- **iOS**: not yet configured (bundle id is still the default `com.example.narcisNadzorniki`; TestFlight setup is a separate task).

## 2. Local Dev Build
```bash
flutter pub get
flutter run -d <device_id>      # debug build, hot reload
flutter test                    # unit/widget tests
flutter analyze                 # static analysis
```

## 3. Android Release Pipeline (Play Console internal testing)

### 3.1 One-time setup (already done as of 2026-04-28)

**Application identity:**
- `applicationId` and `namespace`: `si.terenska.beleznica` (set in `android/app/build.gradle.kts`).
- App label: "Terenska beležnica" (`android/app/src/main/AndroidManifest.xml`).
- Launcher icon: see OPERATIONS §11.

**Upload signing key:**
- Keystore: `/Users/Alexis/keystores/narcis_nadzorniki_upload.jks` (RSA 2048, 25-year validity, alias `upload`, owner `CN=Terenska beleznica, OU=Alittis, O=Alittis, L=Ljubljana, ST=Slovenia, C=SI`).
- File mode `0600`. **Stored outside the repo.** Lose this file → cannot publish updates without rotating the upload key via Play Console support.
- Signing config in `android/app/build.gradle.kts` reads passwords from `android/key.properties` (gitignored, `0600`). Passwords are plain text on disk by Gradle's design — protected by file permissions, not by encryption.
- Upload cert SHA-1: `66:06:D2:3D:09:96:28:4B:10:05:29:F1:07:99:CA:C1:FC:D7:CA:19`
- Upload cert SHA-256: `25:F1:C4:C6:20:C5:33:39:D3:8A:53:11:6C:7A:44:70:53:BD:FC:99:E8:1E:9F:AE:CA:D3:4D:BB:38:B5:E6:A2`

These fingerprints are public (they're the public-key cert digest). Not the same as the **app-signing key** that Play assigns under Play App Signing — Google holds that one and exposes its fingerprint in Play Console after the first upload; record it in `STATE.json` once available.

**Privacy policy:**
- Hosted at `https://alittis.github.io/terenska-beleznica/privacy/` (source: `~/Documents/PROJEKTI/alittis.github.io/terenska-beleznica/privacy/index.html`, served via the `Alittis/alittis.github.io` repo).
- Slovenian primary text. Names ARSO (`narcis.arso@gov.si`) as data controller for submitted records and Alittis (`admin@alittis.com`) as Play Store publisher / developer contact.
- Edit + push from that repo to update — Play Console reads the URL live.

**Permissions philosophy:**
- The manifest declares **only** permissions the app actually requests at runtime. `ACCESS_BACKGROUND_LOCATION` is intentionally NOT declared: walk tracking uses a foreground service typed `location`, which Android grants continuous location to without the background-location permission. Re-declaring it would force a "prominent disclosure" review form for a feature we don't have. See the comment in `AndroidManifest.xml` for the gating rule before adding it back.

### 3.2 Per-release build

Bump `version: X.Y.Z+B` in `pubspec.yaml` (Play requires monotonic `versionCode` = `+B`), then:

```bash
flutter pub get
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab (~45 MB at v1.0.0+1)
```

Sanity-check the signed AAB before upload:
```bash
# Confirm the merged manifest has the right applicationId and no surprise permissions
mkdir -p /tmp/aab && unzip -qo build/app/outputs/bundle/release/app-release.aab -d /tmp/aab
strings /tmp/aab/base/manifest/AndroidManifest.xml | \
  grep -E 'si\.terenska|com\.example|BACKGROUND_LOCATION|FOREGROUND_SERVICE|CAMERA|POST_NOTIFICATIONS' | sort -u
```
Expected: `si.terenska.beleznica` present; `com.example` and `BACKGROUND_LOCATION` absent.

Upload the AAB to **Google Play Console → Internal testing → Create new release**, attach the testers list, and roll out. Play App Signing re-signs with the app-signing key automatically.

### 3.3 Rollback
Play Console doesn't allow rollback of an internal-testing release in place — instead, build a higher `versionCode` with the previous source state and roll that out:
```bash
git checkout <previous-tag>
# Bump versionCode in pubspec.yaml above the bad release, keep versionName the same or note in release notes
flutter build appbundle --release
# Upload as a new internal-testing release
```

## 4. Required environment / secrets
| Item | Where it lives | Notes |
|---|---|---|
| Upload keystore (`.jks`) | `~/keystores/narcis_nadzorniki_upload.jks` | NEVER commit; back up offline |
| `key.properties` | `android/key.properties` (gitignored, `0600`) | Plain-text passwords by Gradle's design |
| Play Console account | `admin@alittis.com` (Alittis) | 2FA strongly recommended |

## 5. Deployment Risks
- **Lost upload keystore** → cannot publish updates. Mitigation: keep an encrypted offline backup of `narcis_nadzorniki_upload.jks` plus the passwords (separate location). Recovery via Play Console support is possible but slow.
- **Bumping `applicationId`** → would create a *new app* on Play; existing installs cannot upgrade. The id is locked at `si.terenska.beleznica`.
- **Re-adding background permissions later** → triggers a Play Console review form (1–3 weeks). Plan around it.
- **Privacy policy URL drift** → if the policy URL ever 404s, Play can suspend the listing. Edits to the policy must keep the URL stable.
