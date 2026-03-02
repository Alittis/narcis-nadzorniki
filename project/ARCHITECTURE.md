# Project Architecture

## 1. Overview
`narcis-nadzorniki` is a Flutter application repository targeting mobile (Android/iOS) and additional Flutter platforms (`web`, `linux`, `macos`, `windows` scaffolding present).

## 2. System Components
- Frontend
  - Flutter UI in `lib/`.
- Backend
  - No backend service implementation detected in this repository root.
- Database
  - No database service configuration detected.
- External Services
  - STATUS: UNKNOWN – REQUIRES CONFIRMATION.
- Infrastructure Components
  - Flutter toolchain build system.

## 3. Repository Structure
- `lib/` — application source
- `android/`, `ios/` — mobile platform projects
- `web/`, `linux/`, `macos/`, `windows/` — platform targets
- `test/` — Flutter tests
- `assets/` (present in `kolpa`) — bundled resources
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
- Backend/API endpoints and contracts.
- Release pipeline/signing/distribution process.
- CI/CD workflow (none detected in repository root scope).

## Documentation Authority
The /project directory is the single source of truth for:
- Architecture
- Deployment
- Operational procedures

All structural changes must update these documents.
