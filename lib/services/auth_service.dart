import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Outcome of an `AuthService.login` call.
class AuthResult {
  const AuthResult({
    required this.success,
    this.user,
    this.message,
    this.wasOffline = false,
  });

  final bool success;
  final String? user;
  final String? message;

  /// True when a successful login was served from the local PBKDF2 cache
  /// (i.e. no network round-trip succeeded).
  final bool wasOffline;
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

/// Login service. Talks to ORDS over HTTPS using a custom `X-Narcis-Auth`
/// header (the standard `Authorization` header is consumed by ORDS upstream
/// of the handler PL/SQL — see ARCHITECTURE.md §9.1). Caches a PBKDF2 hash of
/// the credentials in flutter_secure_storage so subsequent logins can succeed
/// while offline, up to [maxOfflineWindow] since the last successful online
/// login.
class AuthService {
  AuthService({
    http.Client? client,
    Uri? endpoint,
    AuthCacheStore? cacheStore,
    DateTime Function()? clock,
    Duration maxOfflineWindow = const Duration(days: 14),
    Random? random,
  })  : _client = client ?? http.Client(),
        _endpoint = endpoint ??
            Uri.parse('https://narcis.gov.si/ords/narcis/app-auth/login'),
        _cache = cacheStore ?? _SecureStorageAdapter(),
        _clock = clock ?? DateTime.now,
        _maxOfflineWindow = maxOfflineWindow,
        _random = random ?? Random.secure();

  final http.Client _client;
  final Uri _endpoint;
  final AuthCacheStore _cache;
  final DateTime Function() _clock;
  final Duration _maxOfflineWindow;
  final Random _random;

  // ---- Cache schema ----
  // See ARCHITECTURE.md §8 cleanup checklist; the `algo` tag lets us migrate
  // PBKDF2 parameters by recognizing old caches and forcing online relogin.
  static const _kEmail = 'narcis_auth_email';
  static const _kSalt = 'narcis_auth_salt_b64';
  static const _kHash = 'narcis_auth_hash_b64';
  static const _kLastOnline = 'narcis_auth_last_online_at';
  static const _kAlgo = 'narcis_auth_algo';
  static const _algoCurrent = 'pbkdf2_sha256_100k_v1';
  static const _pbkdf2Iters = 100000;
  static const _pbkdf2KeyBytes = 32;
  static const _saltBytes = 32;

  /// Attempts an online login first (if [online] is true), falling back to
  /// the offline cache only when the online attempt fails with a network
  /// error. A successful 200 refreshes the cache; a 401 wipes it (server
  /// revocation propagates to the device). If [online] is false, goes
  /// straight to the cache.
  Future<AuthResult> login(
    String email,
    String password, {
    required bool online,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty || password.isEmpty) {
      return const AuthResult(
        success: false,
        message: 'Vnesite e-pošto in geslo.',
      );
    }

    if (online) {
      final onlineResult = await _tryOnline(normalizedEmail, password);
      // Network errors (null) drop through to the offline path.
      // Definite 200/401 results are returned directly.
      if (onlineResult != null) return onlineResult;
    }

    return _tryOffline(normalizedEmail, password);
  }

  /// Wipes the offline credential cache. Called on explicit logout.
  Future<void> clearCache() async {
    await Future.wait([
      _cache.delete(_kEmail),
      _cache.delete(_kSalt),
      _cache.delete(_kHash),
      _cache.delete(_kLastOnline),
      _cache.delete(_kAlgo),
    ]);
  }

  // ---- internals ----

  /// Returns a definite [AuthResult] when the server replied (200 or 401),
  /// or `null` when the request couldn't complete (timeout, DNS, connection).
  /// A null return tells the caller to fall through to the offline cache.
  Future<AuthResult?> _tryOnline(String email, String password) async {
    final credsB64 = base64Encode(utf8.encode('$email:$password'));
    try {
      final response = await _client.get(
        _endpoint,
        headers: {'X-Narcis-Auth': 'Basic $credsB64'},
      ).timeout(const Duration(seconds: 15));

      // Body parsing is lenient: ARCHITECTURE.md §9.1 notes that this ORDS
      // returns Content-Type: text/html;charset=utf-8 even though the body is
      // valid JSON. We parse by content, not by header.
      Map<String, dynamic> body = const <String, dynamic>{};
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {
          // Non-JSON body is treated as an empty map — status code drives
          // success/failure below.
        }
      }

      if (response.statusCode == 200 && body['authenticated'] == true) {
        final user = (body['user'] as String?) ?? email;
        await _writeCache(email: user, password: password);
        return AuthResult(success: true, user: user);
      }

      if (response.statusCode == 401) {
        // Definite server rejection. Nuke any cached creds so a previously
        // authorized user who has since had TERENSKA-BELEZNICA revoked can no
        // longer log in offline.
        await clearCache();
        return AuthResult(
          success: false,
          message: (body['message'] as String?) ?? 'Prijava ni uspela.',
        );
      }

      // 5xx or other unexpected status: treat as a network error and let
      // the offline path try.
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      // Socket / DNS / TLS: also a network error.
      return null;
    }
  }

  Future<AuthResult> _tryOffline(String email, String password) async {
    final cached = await _readCache();
    if (cached == null || cached.email != email) {
      return const AuthResult(
        success: false,
        message: 'Brez povezave: nimamo shranjenih podatkov za ta račun.',
      );
    }

    if (cached.algo != _algoCurrent) {
      // Stored cache uses a hash scheme we no longer accept. Force online.
      return const AuthResult(
        success: false,
        message: 'Brez povezave: shranjeni podatki so zastareli, '
            'prijavite se z internetno povezavo.',
      );
    }

    final age = _clock().difference(cached.lastOnlineAt);
    if (age.isNegative || age > _maxOfflineWindow) {
      return AuthResult(
        success: false,
        message: 'Brez povezave: dovoljeno obdobje '
            '(${_maxOfflineWindow.inDays} dni) je poteklo. '
            'Prijavite se z internetno povezavo.',
      );
    }

    final candidate = _pbkdf2Sha256(
      password: utf8.encode(password),
      salt: cached.salt,
      iterations: _pbkdf2Iters,
      keyBytes: _pbkdf2KeyBytes,
    );

    if (!_constantTimeEquals(candidate, cached.hash)) {
      return const AuthResult(
        success: false,
        message: 'Brez povezave: napačno geslo.',
      );
    }

    return AuthResult(success: true, user: email, wasOffline: true);
  }

  Future<void> _writeCache({
    required String email,
    required String password,
  }) async {
    final salt = _randomBytes(_saltBytes);
    final hash = _pbkdf2Sha256(
      password: utf8.encode(password),
      salt: salt,
      iterations: _pbkdf2Iters,
      keyBytes: _pbkdf2KeyBytes,
    );
    final now = _clock().toUtc().toIso8601String();

    // Order matters: write the email LAST. _readCache treats "no email" as
    // "no cache", so a partial-write that crashes mid-way leaves the cache
    // effectively empty rather than half-populated.
    await _cache.write(_kAlgo, _algoCurrent);
    await _cache.write(_kSalt, base64Encode(salt));
    await _cache.write(_kHash, base64Encode(hash));
    await _cache.write(_kLastOnline, now);
    await _cache.write(_kEmail, email.toLowerCase());
  }

  Future<_CachedAuth?> _readCache() async {
    final email = await _cache.read(_kEmail);
    if (email == null) return null;

    final saltB64 = await _cache.read(_kSalt);
    final hashB64 = await _cache.read(_kHash);
    final lastOnline = await _cache.read(_kLastOnline);
    final algo = await _cache.read(_kAlgo);
    if (saltB64 == null ||
        hashB64 == null ||
        lastOnline == null ||
        algo == null) {
      return null;
    }

    final ts = DateTime.tryParse(lastOnline);
    if (ts == null) return null;

    return _CachedAuth(
      email: email,
      salt: base64Decode(saltB64),
      hash: base64Decode(hashB64),
      lastOnlineAt: ts,
      algo: algo,
    );
  }

  Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// PBKDF2-HMAC-SHA256. Implemented inline to avoid pulling in a heavier
  /// crypto dep just for this. RFC 8018 §5.2.
  static Uint8List _pbkdf2Sha256({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyBytes,
  }) {
    final hmac = Hmac(sha256, password);
    const hLen = 32; // SHA-256 output length in bytes
    final blocks = (keyBytes + hLen - 1) ~/ hLen;
    final out = BytesBuilder();

    for (var i = 1; i <= blocks; i++) {
      // U_1 = PRF(P, S || INT(i))
      final block = Uint8List.fromList([
        ...salt,
        (i >> 24) & 0xff,
        (i >> 16) & 0xff,
        (i >> 8) & 0xff,
        i & 0xff,
      ]);
      var u = Uint8List.fromList(hmac.convert(block).bytes);
      final t = Uint8List.fromList(u);
      // T_i = U_1 XOR U_2 XOR ... XOR U_c
      for (var j = 1; j < iterations; j++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var k = 0; k < hLen; k++) {
          t[k] ^= u[k];
        }
      }
      out.add(t);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, keyBytes));
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _CachedAuth {
  _CachedAuth({
    required this.email,
    required this.salt,
    required this.hash,
    required this.lastOnlineAt,
    required this.algo,
  });

  final String email;
  final Uint8List salt;
  final Uint8List hash;
  final DateTime lastOnlineAt;
  final String algo;
}
