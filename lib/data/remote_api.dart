import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:narcis_nadzorniki/models/disturbance.dart';

/// In-memory carrier for the credentials needed to call the disturbance
/// CRUD endpoints. The plaintext password is required because every call
/// re-sends `X-Narcis-Auth: Basic <base64(email:password)>` (same wire format
/// as `/app-auth/login`). See ARCHITECTURE.md §9bis / §12.
class SyncCredentials {
  const SyncCredentials({required this.email, required this.password});

  final String email;
  final String password;

  String get authHeaderValue =>
      'Basic ${base64Encode(utf8.encode('$email:$password'))}';
}

/// Thrown for any non-success response from the disturbance endpoints, plus
/// network errors (in which case [statusCode] is null). Callers distinguish
/// 401 (password no longer accepted) from transient/network failures so they
/// can decide whether to keep retrying.
class RemoteApiException implements Exception {
  RemoteApiException({this.statusCode, this.body, this.cause});

  final int? statusCode;
  final String? body;
  final Object? cause;

  bool get isUnauthorized => statusCode == 401;
  bool get isNetwork => statusCode == null;

  @override
  String toString() {
    if (statusCode == null) return 'RemoteApiException(network: $cause)';
    return 'RemoteApiException($statusCode): ${body ?? ''}';
  }
}

/// HTTP client for the disturbance CRUD endpoints at
/// `https://narcis.gov.si/ords/narcis/disturbances/`. See ARCHITECTURE.md §9.3.
class RemoteApi {
  RemoteApi({http.Client? client, Uri? baseUrl, Duration? timeout})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ??
            Uri.parse('https://narcis.gov.si/ords/narcis/disturbances/'),
        _timeout = timeout ?? const Duration(seconds: 30);

  final http.Client _client;
  final Uri _baseUrl;
  final Duration _timeout;

  Future<void> createRecord(
    Disturbance disturbance,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.post(
        _baseUrl,
        headers: _headers(credentials),
        body: jsonEncode(_payload(disturbance)),
      ),
    );
    // 200 = idempotent re-create (server already had this UUID); 201 = new.
    _ensureStatus(response, const {200, 201});
  }

  Future<void> updateRecord(
    Disturbance disturbance,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.put(
        _recordUri(disturbance.id),
        headers: _headers(credentials),
        body: jsonEncode(_payload(disturbance)),
      ),
    );
    _ensureStatus(response, const {200});
  }

  Future<void> deleteRecord(
    String id,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.delete(
        _recordUri(id),
        headers: _headers(credentials),
      ),
    );
    // 404 is acceptable for delete: the desired end state ("not on server")
    // already holds, e.g. local row was never synced or was already deleted.
    _ensureStatus(response, const {200, 204, 404});
  }

  Uri _recordUri(String id) =>
      _baseUrl.resolve(Uri.encodeComponent(id));

  Map<String, String> _headers(SyncCredentials credentials) => {
        'X-Narcis-Auth': credentials.authHeaderValue,
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      };

  Map<String, dynamic> _payload(Disturbance d) => {
        'id': d.id,
        'latitude': d.latitude,
        'longitude': d.longitude,
        'locationAccuracy': d.locationAccuracy,
        'observedAt': d.observedAt.toUtc().toIso8601String(),
        'types': d.types
            .map((t) => {
                  'groupCode': t.groupCode,
                  'typeCode': t.typeCode,
                })
            .toList(),
        'description': d.description,
        'observers': d.observers,
        'actionTaken': d.actionTaken,
        'proposedType': d.proposedType,
      };

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException catch (e) {
      throw RemoteApiException(cause: e);
    } catch (e) {
      // Socket / DNS / TLS / etc. — surfaces as a network error to the caller.
      throw RemoteApiException(cause: e);
    }
  }

  void _ensureStatus(http.Response response, Set<int> acceptable) {
    if (!acceptable.contains(response.statusCode)) {
      throw RemoteApiException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }
}
