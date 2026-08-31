import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/walk.dart';

/// Carrier for the `X-Narcis-Auth` credential sent on every disturbance/walk
/// CRUD call. See ARCHITECTURE.md §9bis.
class SyncCredentials {
  /// Preferred: a bearer session token minted by `/app-auth/login`. Sent as
  /// `X-Narcis-Auth: Bearer <token>` so the user's password is never re-sent.
  const SyncCredentials.token(String token) : authHeaderValue = 'Bearer $token';

  /// Fallback for a backend that didn't mint a token (older ORDS deploy): the
  /// password is held in memory for the session only and sent as
  /// `X-Narcis-Auth: Basic <base64(email:password)>`. Never persisted.
  SyncCredentials.basic({required String email, required String password})
      : authHeaderValue =
            'Basic ${base64Encode(utf8.encode('$email:$password'))}';

  /// The full `X-Narcis-Auth` header value (scheme + credential).
  final String authHeaderValue;
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
    required this.legalBasis,
    required this.caseStatus,
    required this.proposedType,
    required this.createdAt,
    required this.createdBy,
    required this.obhodId,
    required this.reviewedBy,
    required this.reviewedAt,
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
  final String? legalBasis;
  final String caseStatus;
  final String? proposedType;
  final DateTime createdAt;
  final String? createdBy;
  final String? obhodId;
  // Case review, web-owned and read-only here (TB-26); see Disturbance.
  final String? reviewedBy;
  final DateTime? reviewedAt;
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
      legalBasis: legalBasis,
      caseStatus: caseStatus,
      pendingSync: false,
      createdAt: createdAt,
      proposedType: proposedType,
      createdBy: createdBy,
      obhodId: obhodId,
      reviewedBy: reviewedBy,
      reviewedAt: reviewedAt,
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
      // APEX_JSON elides NULL-valued keys, so legalBasis arrives absent
      // (not `null`) on records with no value. Treat missing == null.
      legalBasis: json['legalBasis'] as String?,
      // caseStatus is NOT NULL DB-side; old rows backfilled to 'Odprto'.
      // Defensive fallback handles a server build that pre-dates this field.
      caseStatus: (json['caseStatus'] as String?) ?? 'Odprto',
      proposedType: json['proposedType'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.parse(json['observedAt'] as String),
      createdBy: json['createdBy'] as String?,
      // The ORDS handler elides keys whose value is NULL via APEX_JSON.write,
      // so a record with no walk link arrives without an `obhodId` key at
      // all - read it as nullable and treat absent === null.
      obhodId: json['obhodId'] as String?,
      // Same NULL-key elision as legalBasis/obhodId above: an unreviewed record
      // arrives with neither key. Absent === not yet reviewed.
      reviewedBy: json['reviewedBy'] as String?,
      reviewedAt: json['reviewedAt'] != null
          ? DateTime.parse(json['reviewedAt'] as String)
          : null,
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

/// Server-shaped walk row returned by `GET /walks/`. Metadata only — the
/// track points live behind `GET /walks/:id/points` to keep the list
/// response light. The local [Walk] type carries client-side fields
/// (pendingSync, in-memory points) that we synthesize during merge.
class RemoteWalk {
  const RemoteWalk({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.createdAt,
    required this.pointCount,
    required this.disturbanceCount,
    this.name,
    this.notes,
    this.createdBy,
  });

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final DateTime createdAt;
  final int pointCount;
  final int disturbanceCount;
  final String? name;
  final String? notes;
  final String? createdBy;

  Walk toLocal() {
    return Walk(
      id: id,
      startedAt: startedAt,
      endedAt: endedAt,
      pendingSync: false,
      name: name,
      notes: notes,
      createdBy: createdBy,
      points: const [],
      pointCount: pointCount,
      disturbanceCount: disturbanceCount,
    );
  }

  factory RemoteWalk.fromJson(Map<String, dynamic> json) {
    return RemoteWalk(
      id: json['id'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.parse(json['startedAt'] as String),
      pointCount: (json['pointCount'] as num?)?.toInt() ?? 0,
      disturbanceCount: (json['disturbanceCount'] as num?)?.toInt() ?? 0,
      name: json['name'] as String?,
      notes: json['notes'] as String?,
      createdBy: json['createdBy'] as String?,
    );
  }
}

/// HTTP client for the disturbance + walk-around CRUD endpoints at
/// `https://narcis.gov.si/ords/narcis/`. See ARCHITECTURE.md §9.3 and §9.4.
class RemoteApi {
  RemoteApi({
    http.Client? client,
    Uri? baseUrl,
    Uri? walksBaseUrl,
    Duration? timeout,
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ??
            Uri.parse('https://narcis.gov.si/ords/narcis/disturbances/'),
        _walksBaseUrl = walksBaseUrl ??
            Uri.parse('https://narcis.gov.si/ords/narcis/walks/'),
        _timeout = timeout ?? const Duration(seconds: 30);

  final http.Client _client;
  final Uri _baseUrl;
  final Uri _walksBaseUrl;
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

  Future<List<RemoteWalk>> fetchWalks(SyncCredentials credentials) async {
    final response = await _send(
      () => _client.get(_walksBaseUrl, headers: _jsonHeaders(credentials)),
    );
    _ensureStatus(response, const {200});
    final decoded = jsonDecode(response.body);
    final List<dynamic> walks;
    if (decoded is Map<String, dynamic> && decoded['walks'] is List) {
      walks = decoded['walks'] as List<dynamic>;
    } else {
      throw RemoteApiException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    return walks
        .map((e) => RemoteWalk.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<WalkPoint>> fetchWalkPoints(
    String walkId,
    SyncCredentials credentials,
  ) async {
    final response = await _send(
      () => _client.get(
        _walkPointsUri(walkId),
        headers: _jsonHeaders(credentials),
      ),
    );
    _ensureStatus(response, const {200});
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final pts = decoded['points'] as List<dynamic>? ?? const [];
    return pts
        .map((e) => WalkPoint.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createWalk(Walk walk, SyncCredentials credentials) async {
    final response = await _send(
      () => _client.post(
        _walksBaseUrl,
        headers: _jsonHeaders(credentials),
        body: jsonEncode(_walkPayload(walk)),
      ),
    );
    _ensureStatus(response, const {200, 201});
  }

  /// Updates the walk's name + notes. Server rejects any attempt to mutate
  /// times or points; we don't even send them.
  Future<void> updateWalk(Walk walk, SyncCredentials credentials) async {
    final response = await _send(
      () => _client.put(
        _walkUri(walk.id),
        headers: _jsonHeaders(credentials),
        body: jsonEncode({'name': walk.name, 'notes': walk.notes}),
      ),
    );
    _ensureStatus(response, const {200});
  }

  Future<void> deleteWalk(String id, SyncCredentials credentials) async {
    final response = await _send(
      () => _client.delete(
        _walkUri(id),
        headers: _jsonHeaders(credentials),
      ),
    );
    _ensureStatus(response, const {200, 204, 404});
  }

  Uri _walkUri(String id) => _walksBaseUrl.resolve(Uri.encodeComponent(id));
  Uri _walkPointsUri(String id) =>
      _walksBaseUrl.resolve('${Uri.encodeComponent(id)}/points');

  Map<String, dynamic> _walkPayload(Walk w) => {
        'id': w.id,
        'startedAt': w.startedAt.toUtc().toIso8601String(),
        'endedAt': w.endedAt.toUtc().toIso8601String(),
        'name': w.name,
        'notes': w.notes,
        'points': w.points.map((p) => p.toJson()).toList(),
      };

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
        'legalBasis': d.legalBasis,
        'caseStatus': d.caseStatus,
        'proposedType': d.proposedType,
        'obhodId': d.obhodId,
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
