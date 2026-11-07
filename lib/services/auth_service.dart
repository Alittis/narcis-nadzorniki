import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:narcis_nadzorniki/app_version.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart' show kBeleznicaApi;

/// Outcome of an `AuthService.login` call.
class AuthResult {
  const AuthResult({
    required this.success,
    this.user,
    this.message,
    this.rejectedByServer = false,
    this.token,
    this.reason,
    this.updateRequired = false,
  });

  final bool success;
  final String? user;
  final String? message;

  /// True when the server answered 401.
  final bool rejectedByServer;

  /// Why the server refused a sign-in that succeeded at Račun NarcIS (TB-28 half 2):
  /// `not_authorized` (no TERENSKA-BELEZNICA) or `no_org` (no organisation, so
  /// nothing captured could be stored). Null for a wrong password, which keeps
  /// the one generic message.
  final String? reason;

  /// The server answered 426: this build is below its minimum (TB-46). Any
  /// stored session is left as it is.
  final bool updateRequired;

  /// Bearer session token minted by the server on a successful sign-in.
  /// Persisted by [AuthService] so the session survives app restart.
  final String? token;
}

/// A persisted session restored on app start: the logged-in email plus the
/// bearer token to authenticate sync calls. Returned by
/// [AuthService.readStoredSession].
class StoredSession {
  const StoredSession({required this.email, required this.token});

  final String email;
  final String token;
}

/// Abstraction over `flutter_secure_storage` so tests can substitute a map.
abstract class AuthCacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _SecureStorageAdapter implements AuthCacheStore {
  _SecureStorageAdapter([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Račun NarcIS, where the app signs in (NV-554 P3). A debug build points it at
/// a local provider: `--dart-define=RACUN_ISSUER=http://127.0.0.1:3811` with
/// `adb reverse tcp:3811 tcp:3811`.
const String kRacunIssuer = String.fromEnvironment(
  'RACUN_ISSUER',
  defaultValue: 'https://prijava.alittis.com',
);

/// The app's client at Račun NarcIS and its redirect (narcis-racun RN-18): a
/// private-use scheme, claimed on Android through `appAuthRedirectScheme`
/// (android/app/build.gradle.kts) and on iOS through `CFBundleURLTypes`.
const String kRacunClient = 'terenska-beleznica';
const String kRacunRedirect = 'si.terenska.beleznica:/prijava';

/// What the browser step hands back: the code, and what binds it to this
/// request (the PKCE verifier and the nonce the app sent).
class BrowserCode {
  const BrowserCode({
    required this.code,
    required this.codeVerifier,
    required this.nonce,
  });

  final String code;
  final String codeVerifier;
  final String nonce;
}

/// The person closed the browser, or tapped back, before signing in.
class BrowserSignInCancelled implements Exception {
  const BrowserSignInCancelled();
}

/// The browser step ended without a code. [error] is the OAuth error when the
/// provider sent one (`access_denied` after *Zavrni*).
class BrowserSignInFailed implements Exception {
  const BrowserSignInFailed(this.error);

  final String? error;
}

/// The browser step, behind an interface so tests can stand in for it.
abstract class BrowserSignIn {
  /// Opens Račun NarcIS; returns the code, or throws [BrowserSignInCancelled]
  /// or [BrowserSignInFailed].
  Future<BrowserCode> authorize();
}

/// The browser step through flutter_appauth (AppAuth: Custom Tabs on Android,
/// ASWebAuthenticationSession on iOS). Only `authorize` — the code exchange is
/// narcis-vibed's (`prijava/koda`), which holds the client's secret, so the
/// provider's tokens never reach the phone.
class AppAuthBrowserSignIn implements BrowserSignIn {
  AppAuthBrowserSignIn([FlutterAppAuth? appAuth, Random? random])
    : _appAuth = appAuth ?? const FlutterAppAuth(),
      _random = random ?? Random.secure();

  final FlutterAppAuth _appAuth;
  final Random _random;

  @override
  Future<BrowserCode> authorize() async {
    final nonce = base64UrlEncode(
      List<int>.generate(24, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    try {
      final r = await _appAuth.authorize(
        AuthorizationRequest(
          kRacunClient,
          kRacunRedirect,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: '$kRacunIssuer/oidc/auth',
            tokenEndpoint: '$kRacunIssuer/oidc/token',
          ),
          scopes: const ['openid', 'email', 'profile', 'narcis'],
          nonce: nonce,
          allowInsecureConnections: kRacunIssuer.startsWith('http://'),
        ),
      );
      final code = r.authorizationCode;
      final verifier = r.codeVerifier;
      if (code == null || verifier == null) {
        throw const BrowserSignInFailed(null);
      }
      return BrowserCode(
        code: code,
        codeVerifier: verifier,
        nonce: r.nonce ?? nonce,
      );
    } on FlutterAppAuthUserCancelledException {
      throw const BrowserSignInCancelled();
    } on FlutterAppAuthPlatformException catch (e) {
      throw BrowserSignInFailed(e.platformErrorDetails.error);
    } on PlatformException catch (e) {
      throw BrowserSignInFailed(e.code);
    }
  }
}

/// Sign-in service (NV-554 P3). The person signs in at Račun NarcIS in the
/// phone's browser — a fresh password every time, the second factor where the
/// account needs one, and the consent screen — and the app hands the code to
/// the field-app API's `prijava/koda` ([kBeleznicaApi]), which redeems it and
/// answers with this app's Bearer, as `prijava` did. The app never sees the
/// password, so there is no offline password check any more: a signed-in
/// phone stays signed in across restarts without signal (the stored Bearer),
/// and only a new sign-in needs signal.
class AuthService {
  AuthService({
    http.Client? client,
    Uri? endpoint,
    AuthCacheStore? cacheStore,
    BrowserSignIn? browser,
  }) : _client = client ?? http.Client(),
       _endpoint = endpoint ?? Uri.parse('$kBeleznicaApi/prijava'),
       _cache = cacheStore ?? _SecureStorageAdapter(),
       _browser = browser ?? AppAuthBrowserSignIn();

  final http.Client _client;
  final Uri _endpoint;
  final AuthCacheStore _cache;
  final BrowserSignIn _browser;

  // ---- Stored keys ----
  // The signed-in address and this app's Bearer (a narcis-vibed phone session,
  // TB-46 / NV-554 P3: revocable, expiring, never a password). The address is
  // written LAST, so a crash mid-write leaves no session.
  static const _kEmail = 'narcis_auth_email';
  static const _kToken = 'narcis_vibed_token';
  // The ORDS-era TB token (`TB_AUTH_TOKENS`), which the new API cannot verify.
  // Found on the first start after the update: removed, and the user sent to
  // the login screen with the queue untouched (TB-46).
  static const _kLegacyToken = 'narcis_auth_token';
  // Builds up to 1.15 kept a PBKDF2 hash of the password for an offline
  // check. Nothing reads it since P3: it is deleted on start and at sign-in.
  static const _kOldOffline = [
    'narcis_auth_salt_b64',
    'narcis_auth_hash_b64',
    'narcis_auth_last_online_at',
    'narcis_auth_algo',
  ];

  static const _unreachable =
      'Strežnik za prijavo trenutno ni dosegljiv. Poskusite znova pozneje.';

  /// Signs in through the browser. Needs signal ([online]); a definite refusal
  /// by the server (401) clears anything stored, as before.
  Future<AuthResult> login({required bool online}) async {
    if (!online) {
      return const AuthResult(
        success: false,
        message: 'Za prijavo potrebujete internetno povezavo.',
      );
    }
    final BrowserCode code;
    try {
      code = await _browser.authorize();
    } on BrowserSignInCancelled {
      return const AuthResult(
        success: false,
        message: 'Prijava je bila preklicana.',
      );
    } on BrowserSignInFailed catch (e) {
      return AuthResult(
        success: false,
        message: e.error == 'access_denied'
            ? 'Dostopa niste dovolili, zato prijava ni uspela.'
            : 'Prijava v brskalniku ni uspela. Poskusite znova.',
      );
    }
    return _redeem(code);
  }

  /// Wipes the stored session (and any leftover from older builds). Called on
  /// explicit logout and on any definite 401 (server revocation).
  Future<void> clearCache() async {
    await Future.wait([
      _cache.delete(_kEmail),
      _cache.delete(_kToken),
      _cache.delete(_kLegacyToken),
      for (final k in _kOldOffline) _cache.delete(k),
    ]);
  }

  /// Returns a persisted session (email + bearer token) for silent auto-login
  /// on app start, or null if none is stored. The token is validated lazily by
  /// the first authenticated call — a revoked/expired token 401s, which clears
  /// the session.
  Future<StoredSession?> readStoredSession() async {
    // TB-46: a token from the ORDS backend opens nothing on the new one, and
    // sending it would be answered 401. Forget it; this call then finds no
    // session, so the app opens on the login screen. The stores are not
    // touched, so the queue survives.
    if (await _cache.read(_kLegacyToken) != null) {
      await _cache.delete(_kLegacyToken);
    }
    // P3: the old offline password hash goes; a session stored beside it (a
    // Bearer from the password sign-in) stays and keeps working.
    for (final k in _kOldOffline) {
      if (await _cache.read(k) != null) await _cache.delete(k);
    }
    final email = await _cache.read(_kEmail);
    final token = await _cache.read(_kToken);
    if (email == null || token == null) return null;
    return StoredSession(email: email, token: token);
  }

  /// Best-effort server-side revoke of a bearer token (POST `odjava`).
  /// Network errors are swallowed — the token still expires server-side and the
  /// caller clears the local session regardless.
  Future<void> revokeToken(String token) async {
    try {
      await _client
          .post(
            _endpoint.resolve('odjava'),
            headers: {
              'Authorization': 'Bearer $token',
              'X-App-Build': '$kAppBuild',
            },
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Intentionally ignored.
    }
  }

  // ---- internals ----

  Future<AuthResult> _redeem(BrowserCode code) async {
    try {
      final response = await _client
          .post(
            _endpoint.replace(path: '${_endpoint.path}/koda'),
            headers: {
              'Content-Type': 'application/json',
              'X-App-Build': '$kAppBuild',
            },
            body: jsonEncode({
              'code': code.code,
              'code_verifier': code.codeVerifier,
              'nonce': code.nonce,
            }),
          )
          .timeout(const Duration(seconds: 20));

      // Body parsing is lenient: parse by content, not by header.
      Map<String, dynamic> body = const <String, dynamic>{};
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {
          // Non-JSON body: the status decides below.
        }
      }
      final user = body['user'];
      final token = body['token'];
      if (response.statusCode == 200 &&
          body['authenticated'] == true &&
          user is String &&
          token is String &&
          token.isNotEmpty) {
        await _writeSession(email: user, token: token);
        return AuthResult(success: true, user: user, token: token);
      }
      if (response.statusCode == 426) {
        // Below the server's minimum build (TB-46): nothing is wiped; the app
        // asks for the update.
        return const AuthResult(
          success: false,
          message: 'Ta različica aplikacije ni več podprta.',
          updateRequired: true,
        );
      }
      if (response.statusCode == 401) {
        // A definite refusal: a code the server would not redeem, or a sign-in
        // without TERENSKA-BELEZNICA or an organisation (with a reason).
        await clearCache();
        return AuthResult(
          success: false,
          message: (body['message'] as String?) ?? 'Prijava ni uspela.',
          rejectedByServer: true,
          reason: body['reason'] as String?,
        );
      }
      if (response.statusCode == 400) {
        return const AuthResult(
          success: false,
          message: 'Prijava ni uspela. Poskusite znova.',
        );
      }
      return const AuthResult(success: false, message: _unreachable);
    } on TimeoutException {
      return const AuthResult(success: false, message: _unreachable);
    } catch (_) {
      // Socket / DNS / TLS.
      return const AuthResult(success: false, message: _unreachable);
    }
  }

  Future<void> _writeSession({
    required String email,
    required String token,
  }) async {
    for (final k in _kOldOffline) {
      await _cache.delete(k);
    }
    await _cache.write(_kToken, token);
    await _cache.write(_kEmail, email.toLowerCase());
  }
}
