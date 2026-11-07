// Unit tests for AuthService (NV-554 P3: the browser sign-in).
//
//   * _FakeBrowser stands in for flutter_appauth: it returns a code, or throws
//     the cancel / failure the real one maps from AppAuth.
//   * MockClient (package:http/testing.dart) stands in for the field-app API's
//     `prijava/koda` and `odjava`.
//   * _InMemoryStore stands in for flutter_secure_storage.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/app_version.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';

class _InMemoryStore implements AuthCacheStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeBrowser implements BrowserSignIn {
  _FakeBrowser([this.fail]);

  /// Thrown instead of returning a code.
  final Exception? fail;
  int calls = 0;

  @override
  Future<BrowserCode> authorize() async {
    calls++;
    final f = fail;
    if (f != null) throw f;
    return BrowserCode(code: 'koda-1', codeVerifier: 'v' * 43, nonce: 'n-1');
  }
}

AuthService _service({
  Future<http.Response> Function(http.Request)? respond,
  AuthCacheStore? store,
  BrowserSignIn? browser,
}) {
  return AuthService(
    client: respond == null
        ? MockClient((_) async => http.Response('unexpected', 500))
        : MockClient(respond),
    cacheStore: store ?? _InMemoryStore(),
    browser: browser ?? _FakeBrowser(),
  );
}

http.Response _json(Map<String, Object?> body, int status) => http.Response(
    jsonEncode(body), status,
    // As the server sends it; package:http reads such JSON as UTF-8.
    headers: {'content-type': 'application/json'});

http.Response _ok(String email, String token) => _json(
    {'authenticated': true, 'user': email, 'token': token, 'expiresAt': 'x'},
    200);

void main() {
  group('AuthService.login — the browser sign-in (NV-554 P3)', () {
    test('a code from the browser goes to prijava/koda; the Bearer is stored',
        () async {
      late http.Request sent;
      final store = _InMemoryStore();
      final svc = _service(
        respond: (req) async {
          sent = req;
          return _ok('ana@gov.si', 'tok-1');
        },
        store: store,
      );
      final result = await svc.login(online: true);

      expect(result.success, isTrue);
      expect(result.user, 'ana@gov.si');
      expect(result.token, 'tok-1');
      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/beleznica/app/v1/prijava/koda');
      expect(sent.headers['X-App-Build'], '$kAppBuild');
      expect(sent.headers['Authorization'], isNull, reason: 'no password');
      expect(jsonDecode(sent.body),
          {'code': 'koda-1', 'code_verifier': 'v' * 43, 'nonce': 'n-1'});
      final session = await svc.readStoredSession();
      expect(session?.email, 'ana@gov.si');
      expect(session?.token, 'tok-1');
      expect(store._data['narcis_vibed_token'], 'tok-1');
    });

    test('without signal the browser is not opened', () async {
      final browser = _FakeBrowser();
      final result =
          await _service(browser: browser).login(online: false);
      expect(result.success, isFalse);
      expect(result.message, 'Za prijavo potrebujete internetno povezavo.');
      expect(browser.calls, 0);
    });

    test('a closed browser is a cancel, nothing is sent', () async {
      var calls = 0;
      final result = await _service(
        respond: (_) async {
          calls++;
          return _ok('ana@gov.si', 'tok-1');
        },
        browser: _FakeBrowser(const BrowserSignInCancelled()),
      ).login(online: true);
      expect(result.success, isFalse);
      expect(result.message, 'Prijava je bila preklicana.');
      expect(calls, 0);
    });

    test('Zavrni on the consent screen says access was not allowed', () async {
      final result = await _service(
        browser: _FakeBrowser(const BrowserSignInFailed('access_denied')),
      ).login(online: true);
      expect(result.success, isFalse);
      expect(result.message, contains('Dostopa niste dovolili'));
    });

    test('a refusal after a good sign-in carries its reason (TB-28) and '
        'clears the stored session', () async {
      for (final reason in ['not_authorized', 'no_org']) {
        final store = _InMemoryStore()
          .._data['narcis_auth_email'] = 'old@gov.si'
          .._data['narcis_vibed_token'] = 'old';
        final result = await _service(
          respond: (_) async => _json({
            'authenticated': false,
            'reason': reason,
            'message': 'Prijava je uspela, vendar …',
          }, 401),
          store: store,
        ).login(online: true);
        expect(result.success, isFalse);
        expect(result.rejectedByServer, isTrue);
        expect(result.reason, reason);
        expect(result.message, 'Prijava je uspela, vendar …');
        expect(store._data, isEmpty, reason: 'a 401 still wipes the session');
      }
    });

    test('426 asks for the update and touches nothing stored', () async {
      final store = _InMemoryStore()
        .._data['narcis_auth_email'] = 'ana@gov.si'
        .._data['narcis_vibed_token'] = 'tok-0';
      final before = Map.of(store._data);
      final result = await _service(
        respond: (_) async =>
            _json({'error': 'update_required', 'minBuild': 99}, 426),
        store: store,
      ).login(online: true);
      expect(result.success, isFalse);
      expect(result.updateRequired, isTrue);
      expect(result.rejectedByServer, isFalse);
      expect(store._data, before);
    });

    test('503, a 200 without a token, or a dead network: a message, nothing '
        'stored or wiped', () async {
      final answers = <Future<http.Response> Function(http.Request)>[
        (_) async => _json({'authenticated': false}, 503),
        (_) async => _json({'authenticated': true, 'user': 'ana@gov.si'}, 200),
        (_) async => throw const _FakeNetworkException(),
      ];
      for (final respond in answers) {
        final store = _InMemoryStore().._data['narcis_auth_email'] = 'x@gov.si';
        final result =
            await _service(respond: respond, store: store).login(online: true);
        expect(result.success, isFalse);
        expect(result.rejectedByServer, isFalse);
        expect(result.message, contains('ni dosegljiv'));
        expect(store._data, {'narcis_auth_email': 'x@gov.si'});
      }
    });
  });

  group('the stored session', () {
    test('an upgrade from a password build keeps its session and drops the '
        'old offline password hash', () async {
      final store = _InMemoryStore()
        .._data['narcis_auth_email'] = 'ana@gov.si'
        .._data['narcis_vibed_token'] = 'tok-old'
        .._data['narcis_auth_salt_b64'] = 's'
        .._data['narcis_auth_hash_b64'] = 'h'
        .._data['narcis_auth_last_online_at'] = '2026-11-01T00:00:00Z'
        .._data['narcis_auth_algo'] = 'pbkdf2_sha256_100k_v1';
      final session = await _service(store: store).readStoredSession();
      expect(session?.email, 'ana@gov.si');
      expect(session?.token, 'tok-old');
      expect(store._data.keys.toSet(),
          {'narcis_auth_email', 'narcis_vibed_token'});
    });

    test('an ORDS-era token is forgotten on start: no session (TB-46)',
        () async {
      final store = _InMemoryStore()
        .._data['narcis_auth_email'] = 'ana@gov.si'
        .._data['narcis_auth_token'] = 'a' * 64;
      expect(await _service(store: store).readStoredSession(), isNull);
      expect(store._data.containsKey('narcis_auth_token'), isFalse);
    });

    test('clearCache removes everything stored', () async {
      final store = _InMemoryStore();
      final svc = _service(
          respond: (_) async => _ok('ana@gov.si', 'tok-1'), store: store);
      await svc.login(online: true);
      store._data['narcis_auth_token'] = 'legacy';
      await svc.clearCache();
      expect(store._data, isEmpty);
      expect(await svc.readStoredSession(), isNull);
    });

    test('revokeToken POSTs to odjava with the Bearer and this build',
        () async {
      late http.Request captured;
      await _service(
        respond: (req) async {
          captured = req;
          return http.Response('{"revoked":true}', 200);
        },
      ).revokeToken('tok-xyz');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/beleznica/app/v1/odjava');
      expect(captured.headers['Authorization'], 'Bearer tok-xyz');
      expect(captured.headers['X-App-Build'], '$kAppBuild');
    });
  });
}

/// A network-layer failure (timeout, DNS, TLS) as the HTTP client throws it.
class _FakeNetworkException implements Exception {
  const _FakeNetworkException();
}
