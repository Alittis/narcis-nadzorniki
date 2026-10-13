/// This build's number — the `+N` of `version:` in pubspec.yaml — sent to the
/// field-app API as `X-App-Build` on every call (TB-46). The server answers 426
/// below its minimum (narcis-vibed `BELEZNICA_APP_MIN_BUILD`), and the app then
/// shows [UpdateRequiredScreen] with its queue kept.
///
/// Dart cannot read the build number without a plugin, so it is written here.
/// Bump it with pubspec.yaml: `test/app_version_test.dart` fails while they
/// differ.
const int kAppBuild = 23;
