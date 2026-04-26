import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

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
  bool get isNotFound => statusCode == 404;
  bool get isNetwork => statusCode == null;

  @override
  String toString() {
    if (statusCode == null) return 'RemoteApiException(network: $cause)';
    return 'RemoteApiException($statusCode): ${body ?? ''}';
  }
}

/// Server-shaped record returned by `GET /disturbances/`. The local
/// `Disturbance` carries a few client-side fields (createdAt may be local,
/// pendingSync, photo localPath) that we synthesize during merge - this
/// type is the on-the-wire view, kept distinct so callers can't confuse the
/// two.
class RemoteDisturbance {
  const RemoteDisturbance({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.locationAccuracy,
    required this.observedAt,
    required this.types,
    required this.description,
    required this.observers,
    required this.actionTaken,
    required this.proposedType,
    required this.createdAt,
    required this.photos,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String locationAccuracy;
  final DateTime observedAt;
  final List<SelectedDisturbanceType> types;
  final String description;
  final List<String> observers;
  final String actionTaken;
  final String? proposedType;
  final DateTime createdAt;
  final List<DisturbancePhoto> photos;

  /// Convert into a local-store-shaped record. Photos are returned without a
  /// localPath - lazy fetch will populate it on first view.
  Disturbance toLocal() {
    return Disturbance(
      id: id,
      latitude: latitude,
      longitude: longitude,
      locationAccuracy: locationAccuracy,
      observedAt: observedAt,
      types: types,
      description: description,
      photos: photos,
      observers: observers,
      actionTaken: actionTaken,
      pendingSync: false,
      createdAt: createdAt,
      proposedType: proposedType,
    );
  }

  factory RemoteDisturbance.fromJson(Map<String, dynamic> json) {
    return RemoteDisturbance(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      locationAccuracy: json['locationAccuracy'] as String,
      observedAt: DateTime.parse(json['observedAt'] as String),
      types: (json['types'] as List<dynamic>? ?? const [])
          .map((e) => _readType(e as Map<String, dynamic>))
          .toList(),
      description: (json['description'] as String?) ?? '',
      observers: (json['observers'] as List<dynamic>? ?? const []).cast<String>(),
      actionTaken: json['actionTaken'] as String,
      proposedType: json['proposedType'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.parse(json['observedAt'] as String),
      photos: (json['photos'] as List<dynamic>? ?? const [])
          .map((e) => _readPhoto(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// The GET endpoint returns only `groupCode`/`typeCode`. Names live in the
  /// local codebook; callers that need the display name should resolve it
  /// against `lib/data/disturbance_types.dart`. We store the codes verbatim
  /// here.
  static SelectedDisturbanceType _readType(Map<String, dynamic> json) {
    final groupCode = json['groupCode'] as String;
    final typeCode = json['typeCode'] as String;
    return SelectedDisturbanceType(
      groupCode: groupCode,
      groupName: (json['groupName'] as String?) ?? groupCode,
      typeCode: typeCode,
      typeName: (json['typeName'] as String?) ?? typeCode,
    );
  }

  static DisturbancePhoto _readPhoto(Map<String, dynamic> json) {
    return DisturbancePhoto(
      id: json['id'] as String,
      mimeType: (json['mimeType'] as String?) ?? 'image/jpeg',
      localPath: null,
      pendingUpload: false,
    );
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

  Future<List<RemoteDisturbance>> fetchRecords(SyncCredentials credentials) async {
    final response = await _send(
      () => _client.get(_baseUrl, headers: _jsonHeaders(credentials)),
    );
    _ensureStatus(response, const {200});
    final decoded = jsonDecode(response.body);
    final List<dynamic> records;
    if (decoded is Map<String, dynamic> && decoded['records'] is List) {
      records = decoded['records'] as List<dynamic>;
    } else if (decoded is List) {
      records = decoded;
    } else {
      throw RemoteApiException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    return records
        .map((e) => RemoteDisturbance.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createRecord(
    Disturbance disturbance,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.post(
        _baseUrl,
        headers: _jsonHeaders(credentials),
        body: jsonEncode(_payload(disturbance)),
      ),
    );
    _ensureStatus(response, const {200, 201});
  }

  Future<void> updateRecord(
    Disturbance disturbance,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.put(
        _recordUri(disturbance.id),
        headers: _jsonHeaders(credentials),
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
        headers: _jsonHeaders(credentials),
      ),
    );
    _ensureStatus(response, const {200, 204, 404});
  }

  Future<void> uploadPhoto({
    required String motnjaId,
    required String photoId,
    required Uint8List bytes,
    required String mimeType,
    required SyncCredentials credentials,
  }) async {
    final response = await _send(
      () => _client.post(
        _photoUri(motnjaId, photoId),
        headers: {
          'X-Narcis-Auth': credentials.authHeaderValue,
          'Content-Type': mimeType,
          'Accept': 'application/json',
        },
        body: bytes,
      ),
    );
    _ensureStatus(response, const {200, 201});
  }

  Future<Uint8List> downloadPhoto({
    required String motnjaId,
    required String photoId,
    required SyncCredentials credentials,
  }) async {
    final response = await _send(
      () => _client.get(
        _photoUri(motnjaId, photoId),
        headers: {
          'X-Narcis-Auth': credentials.authHeaderValue,
          'Accept': '*/*',
        },
      ),
    );
    _ensureStatus(response, const {200});
    return response.bodyBytes;
  }

  Future<void> deletePhoto({
    required String motnjaId,
    required String photoId,
    required SyncCredentials credentials,
  }) async {
    final response = await _send(
      () => _client.delete(
        _photoUri(motnjaId, photoId),
        headers: _jsonHeaders(credentials),
      ),
    );
    _ensureStatus(response, const {200, 204, 404});
  }

  Uri _recordUri(String id) => _baseUrl.resolve(Uri.encodeComponent(id));

  Uri _photoUri(String motnjaId, String photoId) =>
      _baseUrl.resolve(
        '${Uri.encodeComponent(motnjaId)}/photos/${Uri.encodeComponent(photoId)}',
      );

  Map<String, String> _jsonHeaders(SyncCredentials credentials) => {
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
