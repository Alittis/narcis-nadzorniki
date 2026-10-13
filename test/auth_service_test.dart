// Unit tests for AuthService.
//
// We exercise the full online + offline matrix using:
//   * MockClient (from package:http/testing.dart) for the HTTP layer, so we
//     don't touch the real ORDS endpoint.
//   * _InMemoryStore as a stand-in for flutter_secure_storage, so tests don't
//     need a platform channel.
//   * A fixed-Random and fixed-clock to make PBKDF2 round-trips deterministic.
//
// PBKDF2 itself is exercised end-to-end (write cache → read cache → verify
// password). We do NOT directly assert the hash bytes, only that the same
// password reproduces the cached hash and a different password does not.

import 'dart:convert';
import 'dart:math';

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

/// Builds an AuthService with controllable dependencies. [respond] handles
/// every HTTP call. [clock] returns the "current" time. [random] seeds the
/// salt generator deterministically.
AuthService _service({
  Future<http.Response> Function(http.Request)? respond,
  DateTime Function()? clock,
  AuthCacheStore? store,
  Duration window = const Duration(days: 14),
}) {
  return AuthService(
    client: respond == null
        ? MockClient((_) async => http.Response('unexpected', 500))
        : MockClient(respond),
    cacheStore: store ?? _InMemoryStore(),
    clock: clock ?? () => DateTime.utc(2026, 4, 25, 12, 0, 0),
    maxOfflineWindow: window,
    random: Random(42),
  );
}

http.Response _ok(String email) =>
    http.Response(jsonEncode({'authenticated': true, 'user': email}), 200);

http.Response _unauthorized() =>
    http.Response(
        jsonEncode({
          'authenticated': false,
          'message': 'Neveljavni podatki za prijavo.',
        }),
        401);

http.Response _okWithToken(String email, String token) => http.Response(
    jsonEncode({'authenticated': true, 'user': email, 'token': token}), 200);

void main() {
  group('AuthService.login (online path)', () {
    test('200 with authenticated:true succeeds', () async {
      final svc = _service(
        respond: (req) async {
          // The wire format (TB-46): POST prijava with
          // Authorization: Basic <base64(email:pw)>.
          expect(req.method, 'POST');
          expect(req.url.path, '/api/beleznica/app/v1/prijava');
          expect(req.headers.containsKey('X-Narcis-Auth'), isFalse);
          final header = req.headers['Authorization'];
          expect(header, startsWith('Basic '));
          final decoded = utf8.decode(base64Decode(header!.substring(6)));
          expect(decoded, 'alice@example.com:hunter2');
          return _ok('alice@example.com');
        },
      );

      final result =
          await svc.login('Alice@Example.com', 'hunter2', online: true);
      expect(result.success, true);
      expect(result.user, 'alice@example.com');
      expect(result.wasOffline, false);
    });

    test('401 fails and wipes any existing cache', () async {
      final store = _InMemoryStore();
      // Pre-seed a cache as if a previous online login had succeeded.
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);
      expect(store._data.containsKey('narcis_auth_email'), true);

      final svc = _service(
        respond: (_) async => _unauthorized(),
        store: store,
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: true);
      expect(result.success, false);
      expect(result.message, contains('Neveljavni'));
      expect(result.rejectedByServer, isTrue, reason: 'TB-28 hint keys on it');
      // Cache must be wiped so a revoked user cannot fall back offline.
      expect(store._data.isEmpty, true);
    });

    test('network error falls through to offline cache when present',
        () async {
      final store = _InMemoryStore();
      // Prime a cache.
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      final svc = _service(
        respond: (_) async => throw const _FakeNetworkException(),
        store: store,
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: true);
      expect(result.success, true);
      expect(result.wasOffline, true);
    });

    test('network error with NO cache fails with informative message',
        () async {
      final svc = _service(
        respond: (_) async => throw const _FakeNetworkException(),
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: true);
      expect(result.success, false);
      expect(result.message, contains('Brez povezave'));
      expect(result.rejectedByServer, isFalse);
    });
  });

  group('AuthService.login (offline path)', () {
    test('online:false uses cache directly', () async {
      final store = _InMemoryStore();
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      final svc = _service(store: store);
      final result =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(result.success, true);
      expect(result.wasOffline, true);
    });

    test('wrong password against valid cache fails', () async {
      final store = _InMemoryStore();
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      final svc = _service(store: store);
      final result =
          await svc.login('alice@example.com', 'WRONG', online: false);
      expect(result.success, false);
      expect(result.message, contains('napačno geslo'));
      expect(result.rejectedByServer, isFalse);
    });

    test('different email against valid cache fails', () async {
      final store = _InMemoryStore();
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      final svc = _service(store: store);
      final result =
          await svc.login('bob@example.com', 'hunter2', online: false);
      expect(result.success, false);
      expect(result.message, contains('nimamo shranjenih'));
    });

    test('cache older than max-offline window fails as expired', () async {
      final store = _InMemoryStore();
      // Seed cache at T0.
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
        clock: () => DateTime.utc(2026, 4, 1, 12, 0, 0),
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      // Try to login offline 15 days later (> 14-day window).
      final svc = _service(
        store: store,
        clock: () => DateTime.utc(2026, 4, 16, 12, 0, 1),
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(result.success, false);
      expect(result.message, contains('poteklo'));
    });

    test('cache exactly at the window edge still succeeds', () async {
      final store = _InMemoryStore();
      final priming = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
        clock: () => DateTime.utc(2026, 4, 1, 12, 0, 0),
      );
      await priming.login('alice@example.com', 'hunter2', online: true);

      // Exactly 14 days later — must still pass (>, not >=).
      final svc = _service(
        store: store,
        clock: () => DateTime.utc(2026, 4, 15, 12, 0, 0),
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(result.success, true);
      expect(result.wasOffline, true);
    });

    test('first-time login while offline (no cache) fails', () async {
      final svc = _service();
      final result =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(result.success, false);
      expect(result.message, contains('Brez povezave'));
    });
  });

  group('AuthService.clearCache', () {
    test('removes all entries so subsequent offline login fails', () async {
      final store = _InMemoryStore();
      final svc = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );

      await svc.login('alice@example.com', 'hunter2', online: true);
      expect(store._data.isEmpty, false);

      await svc.clearCache();
      expect(store._data.isEmpty, true);

      final result =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(result.success, false);
    });
  });

  group('AuthService input validation', () {
    test('empty email or password returns failure without network call',
        () async {
      var calls = 0;
      final svc = _service(
        respond: (_) async {
          calls++;
          return _ok('alice@example.com');
        },
      );

      final r1 = await svc.login('', 'hunter2', online: true);
      expect(r1.success, false);
      final r2 = await svc.login('alice@example.com', '', online: true);
      expect(r2.success, false);
      expect(calls, 0);
    });
  });

  group('AuthService bearer token', () {
    test('online login captures, returns and persists the token', () async {
      final store = _InMemoryStore();
      final svc = _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-xyz'),
        store: store,
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: true);
      expect(result.success, true);
      expect(result.token, 'tok-xyz');

      final session = await svc.readStoredSession();
      expect(session, isNotNull);
      expect(session!.email, 'alice@example.com');
      expect(session.token, 'tok-xyz');
    });

    test('online login with no token leaves no restorable session', () async {
      final store = _InMemoryStore();
      final svc = _service(
        respond: (_) async => _ok('alice@example.com'),
        store: store,
      );
      final result =
          await svc.login('alice@example.com', 'hunter2', online: true);
      expect(result.success, true);
      expect(result.token, isNull);
      // PBKDF2 cache is written, but with no token there is no auto-login.
      expect(await svc.readStoredSession(), isNull);
    });

    test('clearCache removes the persisted token', () async {
      final store = _InMemoryStore();
      final svc = _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-xyz'),
        store: store,
      );
      await svc.login('alice@example.com', 'hunter2', online: true);
      expect(await svc.readStoredSession(), isNotNull);

      await svc.clearCache();
      expect(await svc.readStoredSession(), isNull);
    });

    test('a definite 401 wipes a previously stored token', () async {
      final store = _InMemoryStore();
      final priming = _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-xyz'),
        store: store,
      );
      await priming.login('alice@example.com', 'hunter2', online: true);
      expect(await priming.readStoredSession(), isNotNull);

      final svc = _service(respond: (_) async => _unauthorized(), store: store);
      await svc.login('alice@example.com', 'hunter2', online: true);
      expect(await svc.readStoredSession(), isNull);
    });

    test('revokeToken POSTs to odjava with an Authorization Bearer header',
        () async {
      late http.Request captured;
      final svc = _service(
        respond: (req) async {
          captured = req;
          return http.Response('{"revoked":true}', 200);
        },
      );
      await svc.revokeToken('tok-xyz');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/beleznica/app/v1/odjava');
      expect(captured.headers['Authorization'], 'Bearer tok-xyz');
    });
  });

  // TB-46: the field-app API's login (narcis-vibed NV-259 P4).
  group('the field-app login (TB-46)', () {
    http.Response refused(String reason) => http.Response(
        jsonEncode({
          'authenticated': false,
          'reason': reason,
          'message': 'Geslo je pravilno, vendar …',
        }),
        401,
        // As the server sends it; package:http reads such JSON as UTF-8.
        headers: {'content-type': 'application/json'});

    test('a refusal of a right password carries its reason (TB-28 half 2)',
        () async {
      for (final reason in ['not_authorized', 'no_org']) {
        final store = _InMemoryStore();
        final result = await _service(
          respond: (_) async => refused(reason),
          store: store,
        ).login('alice@example.com', 'hunter2', online: true);
        expect(result.success, isFalse);
        expect(result.rejectedByServer, isTrue);
        expect(result.reason, reason);
        expect(result.message, 'Geslo je pravilno, vendar …');
        expect(store._data, isEmpty, reason: 'a 401 still wipes the cache');
      }
    });

    test('a wrong password has no reason', () async {
      final result = await _service(respond: (_) async => _unauthorized())
          .login('alice@example.com', 'x', online: true);
      expect(result.rejectedByServer, isTrue);
      expect(result.reason, isNull);
    });

    test('503 (NarcIS could not be asked) falls back to the offline cache '
        'and keeps it', () async {
      final store = _InMemoryStore();
      await _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-1'),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);

      final result = await _service(
        respond: (_) async => http.Response(
            '{"authenticated":false,"message":"…ni dosegljiv…"}', 503,
            headers: {'content-type': 'application/json'}),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);
      expect(result.success, isTrue);
      expect(result.wasOffline, isTrue);
      expect(store._data['narcis_auth_email'], 'alice@example.com');
    });

    test('login and logout name this build (X-App-Build)', () async {
      final builds = <String?>[];
      final svc = _service(respond: (req) async {
        builds.add(req.headers['X-App-Build']);
        return _okWithToken('alice@example.com', 'tok-1');
      });
      await svc.login('alice@example.com', 'hunter2', online: true);
      await svc.revokeToken('tok-1');
      expect(builds, ['$kAppBuild', '$kAppBuild']);
    });

    test('426 asks for the update and touches nothing stored', () async {
      final store = _InMemoryStore();
      await _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-1'),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);
      final before = Map.of(store._data);

      final result = await _service(
        respond: (_) async => http.Response(
            '{"error":"update_required","minBuild":99}', 426,
            headers: {'content-type': 'application/json'}),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);
      expect(result.success, isFalse);
      expect(result.updateRequired, isTrue);
      expect(result.rejectedByServer, isFalse);
      expect(result.wasOffline, isFalse, reason: 'no offline fallback');
      expect(store._data, before);
    });

    test('the token is stored under the new key', () async {
      final store = _InMemoryStore();
      await _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-1'),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);
      expect(store._data['narcis_vibed_token'], 'tok-1');
      expect(store._data.containsKey('narcis_auth_token'), isFalse);
    });

    test('an ORDS-era token is forgotten on start: no session, the offline '
        'cache kept', () async {
      final store = _InMemoryStore();
      await _service(
        respond: (_) async => _okWithToken('alice@example.com', 'tok-new'),
        store: store,
      ).login('alice@example.com', 'hunter2', online: true);
      // What the last ORDS build left: the TB token under the old key.
      store._data.remove('narcis_vibed_token');
      store._data['narcis_auth_token'] = 'a' * 64;

      final svc = _service(store: store);
      expect(await svc.readStoredSession(), isNull);
      expect(store._data.containsKey('narcis_auth_token'), isFalse);
      expect(store._data['narcis_auth_email'], 'alice@example.com');
      // …so an offline login still works until the user is back online.
      final offline =
          await svc.login('alice@example.com', 'hunter2', online: false);
      expect(offline.success, isTrue);
    });
  });
}

/// Sentinel used by tests to simulate a network-layer failure (timeout, DNS,
/// TLS). AuthService catches a generic Object/Exception and routes to the
/// offline path, which is what we want to verify.
class _FakeNetworkException implements Exception {
  const _FakeNetworkException();
}
