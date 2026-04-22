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
- Real authentication contract (current `/test/auth` is a test stub; only validates that `username` header equals `alexis.zrimec@gov.si`, password is not checked).
- Final auth mechanism: ORDS First-Party Auth vs OAuth2 vs custom credential check — STATUS: UNKNOWN – REQUIRES CONFIRMATION.
- Disturbance CRUD endpoints on ORDS — not yet implemented; `RemoteApi` is a stub with delays only.
- Release pipeline/signing/distribution process.
- CI/CD workflow (none detected in repository root scope).

## 9. Backend Endpoints
- `GET /narcis/ords/narcis/test/auth`
  - Headers: `username: <email>`
  - 200 with `{"authenticated":true,"user":"<email>"}` if header equals `alexis.zrimec@gov.si`
  - 401 with `{"authenticated":false,"message":"Invalid credentials"}` otherwise
  - CORS: `Access-Control-Allow-Origin: *`
  - Purpose: temporary login probe for Flutter client; replace before production.

## Documentation Authority
The /project directory is the single source of truth for:
- Architecture
- Deployment
- Operational procedures

All structural changes must update these documents.
