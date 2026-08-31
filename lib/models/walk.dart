import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

/// One GPS sample taken during a walk-around. `seq` is a 0-based monotonic
/// integer assigned by the client; `(walkId, seq)` is the server-side PK.
/// Accuracy is in meters and may be null (the OS doesn't always report it).
class WalkPoint {
  const WalkPoint({
    required this.seq,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
  });

  final int seq;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracy;

  LatLng get location => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'lat': latitude,
        'lon': longitude,
        't': timestamp.toUtc().toIso8601String(),
        if (accuracy != null) 'accuracy': accuracy,
      };

  factory WalkPoint.fromJson(Map<String, dynamic> json) {
    return WalkPoint(
      seq: (json['seq'] as num).toInt(),
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lon'] as num).toDouble(),
      timestamp: DateTime.parse(json['t'] as String),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
    );
  }
}

/// A walk-around (Slovene "obhod"): a continuous GPS-tracked field session.
/// Disturbances captured during the walk carry the walk's [id] in their
/// `obhodId` field so the path and observations can be reviewed together.
///
/// Local-only fields:
/// - [pendingSync] is true until the first POST succeeds. Once cleared, the
///   walk is on the server and only [name]/[notes] edits can be re-pushed.
/// - [points] is loaded from the active-walk file while the walk is in
///   progress, and from `walks_local_store.json` after it's saved. After
///   the first successful pull, completed walks are persisted with
///   [points] cleared on disk and lazy-fetched via /walks/:id/points only
///   when the user opens the detail screen — the bulk of the wire payload
///   doesn't need to live in memory or in `walks_store.json` for every walk.
class Walk {
  const Walk({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.pendingSync,
    this.name,
    this.notes,
    this.createdBy,
    this.points = const [],
    this.pointCount,
    this.disturbanceCount,
  });

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool pendingSync;
  final String? name;
  final String? notes;
  final String? createdBy;

  /// Empty when the walk has been pulled from the server but its points have
  /// not been fetched yet. Use [pointCount] to know how many to expect.
  final List<WalkPoint> points;

  /// Server-reported counts for list views. Null for purely local walks.
  final int? pointCount;
  final int? disturbanceCount;

  Duration get duration => endedAt.difference(startedAt);

  /// Best-effort point count for display, falling back to the embedded list
  /// when the walk hasn't been pushed yet (server-side count is null).
  int get displayPointCount => pointCount ?? points.length;

  Walk copyWith({
    DateTime? startedAt,
    DateTime? endedAt,
    bool? pendingSync,
    String? name,
    String? notes,
    String? createdBy,
    List<WalkPoint>? points,
    int? pointCount,
    int? disturbanceCount,
  }) {
    return Walk(
      id: id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      pendingSync: pendingSync ?? this.pendingSync,
      name: name ?? this.name,
      notes: notes ?? this.notes,
      createdBy: createdBy ?? this.createdBy,
      points: points ?? this.points,
      pointCount: pointCount ?? this.pointCount,
      disturbanceCount: disturbanceCount ?? this.disturbanceCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'pendingSync': pendingSync,
        'name': name,
        'notes': notes,
        'createdBy': createdBy,
        'points': points.map((p) => p.toJson()).toList(),
        'pointCount': pointCount,
        'disturbanceCount': disturbanceCount,
      };

  factory Walk.fromJson(Map<String, dynamic> json) {
    return Walk(
      id: json['id'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      pendingSync: (json['pendingSync'] as bool?) ?? false,
      name: json['name'] as String?,
      notes: json['notes'] as String?,
      createdBy: json['createdBy'] as String?,
      points: (json['points'] as List<dynamic>? ?? const [])
          .map((e) => WalkPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      pointCount: (json['pointCount'] as num?)?.toInt(),
      disturbanceCount: (json['disturbanceCount'] as num?)?.toInt(),
    );
  }
}

/// Human label for a walk: its name, or its **local** start time when unnamed —
/// which walks usually are. Shared by Seznam obhodov and the obhod link in
/// Seznam zapisov (TB-17) so the two screens cannot drift into naming the same
/// walk differently.
String walkLabel(Walk walk, DateFormat fmt) =>
    walk.name?.isNotEmpty == true
        ? walk.name!
        : fmt.format(walk.startedAt.toLocal());
