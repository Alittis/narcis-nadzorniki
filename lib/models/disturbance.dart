import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

class Disturbance {
  Disturbance({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.locationAccuracy,
    required this.observedAt,
    required this.types,
    required this.description,
    required this.photos,
    required this.observers,
    required this.actionTaken,
    required this.caseStatus,
    required this.pendingSync,
    required this.createdAt,
    this.pendingDelete = false,
    this.legalBasis,
    this.proposedType,
    this.createdBy,
    this.obhodId,
    this.reviewedBy,
    this.reviewedAt,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String locationAccuracy;
  final DateTime observedAt;
  final List<SelectedDisturbanceType> types;
  final String description;
  final List<DisturbancePhoto> photos;
  final List<String> observers;
  final String actionTaken;
  // Free-text legal basis for the action taken against the perpetrator.
  // Currently nullable; the dropdown will be populated later.
  final String? legalBasis;
  // Workflow state. DB-side CHECK pins this to: 'Odprto', 'V obravnavi',
  // 'Zaključeno', 'Predano drugi službi'. Default 'Odprto' for new records.
  final String caseStatus;
  final bool pendingSync;
  // TB-2: the user deleted this record while the DELETE could not be sent (no
  // network, or no session). The row stays in _records so the queue can find it
  // after a restart, but AppState.records hides it, so every read surface --
  // map, lists, counts -- behaves as though it is already gone. Cleared only by
  // purging the record outright once the server has confirmed the delete.
  final bool pendingDelete;
  final DateTime createdAt;
  final String? proposedType;
  // Email of the user who created the record. Null for local-only records
  // that haven't been pushed yet (the caller is the author by definition);
  // populated from `ustvarjen_od` when pulled from the server.
  final String? createdBy;
  // Walk-around (obhod) the record was captured during. Stamped in
  // `AppState.addRecord` when a walk is active; null otherwise.
  final String? obhodId;
  // Who took the case decision, and when (TB-26). Read-only on the phone: the
  // web backoffice is the sole writer (narcis-vibed NV-220) and `_payload` in
  // remote_api.dart deliberately omits both, so they can never round-trip into
  // a write. Null until a record has actually been reviewed. `reviewedAt`
  // arrives as UTC, like every other instant here -- `.toLocal()` to display.
  final String? reviewedBy;
  final DateTime? reviewedAt;

  bool get hasPendingPhotoUploads => photos.any((p) => p.pendingUpload);

  /// TB-2: the back office has acted on this record, so the phone must not
  /// delete it. Either a reviewer stamped it (TB-26's `reviewedBy`/`reviewedAt`,
  /// which only the web backoffice writes) or the case status has moved off the
  /// create-time default. Deleting such a row would pull the evidence out from
  /// under a decision someone has already taken, and `DELETE :id` is a hard
  /// cascade -- the record, its type/observer junctions and its photos all go,
  /// with nothing to restore from.
  bool get isLockedByReview =>
      reviewedBy != null || reviewedAt != null || caseStatus != 'Odprto';

  Disturbance copyWith({
    double? latitude,
    double? longitude,
    String? locationAccuracy,
    DateTime? observedAt,
    List<SelectedDisturbanceType>? types,
    String? description,
    List<DisturbancePhoto>? photos,
    List<String>? observers,
    String? actionTaken,
    String? legalBasis,
    String? caseStatus,
    bool? pendingSync,
    bool? pendingDelete,
    DateTime? createdAt,
    String? proposedType,
    String? createdBy,
    String? obhodId,
    String? reviewedBy,
    DateTime? reviewedAt,
  }) {
    return Disturbance(
      id: id,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationAccuracy: locationAccuracy ?? this.locationAccuracy,
      observedAt: observedAt ?? this.observedAt,
      types: types ?? this.types,
      description: description ?? this.description,
      photos: photos ?? this.photos,
      observers: observers ?? this.observers,
      actionTaken: actionTaken ?? this.actionTaken,
      legalBasis: legalBasis ?? this.legalBasis,
      caseStatus: caseStatus ?? this.caseStatus,
      pendingSync: pendingSync ?? this.pendingSync,
      pendingDelete: pendingDelete ?? this.pendingDelete,
      createdAt: createdAt ?? this.createdAt,
      proposedType: proposedType ?? this.proposedType,
      createdBy: createdBy ?? this.createdBy,
      obhodId: obhodId ?? this.obhodId,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'locationAccuracy': locationAccuracy,
        'observedAt': observedAt.toIso8601String(),
        'types': types.map((type) => type.toJson()).toList(),
        'description': description,
        'photos': photos.map((p) => p.toJson()).toList(),
        'observers': observers,
        'actionTaken': actionTaken,
        'legalBasis': legalBasis,
        'caseStatus': caseStatus,
        'pendingSync': pendingSync,
        'pendingDelete': pendingDelete,
        'createdAt': createdAt.toIso8601String(),
        'proposedType': proposedType,
        'createdBy': createdBy,
        'obhodId': obhodId,
        'reviewedBy': reviewedBy,
        'reviewedAt': reviewedAt?.toIso8601String(),
      };

  factory Disturbance.fromJson(Map<String, dynamic> json) {
    return Disturbance(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      locationAccuracy: json['locationAccuracy'] as String,
      observedAt: DateTime.parse(json['observedAt'] as String),
      types: (json['types'] as List<dynamic>)
          .map((entry) => SelectedDisturbanceType.fromJson(entry as Map<String, dynamic>))
          .toList(),
      description: json['description'] as String,
      photos: _readPhotos(json),
      observers: (json['observers'] as List<dynamic>).cast<String>(),
      actionTaken: json['actionTaken'] as String,
      // Records persisted before these fields existed will be missing both
      // keys; default legalBasis to null and caseStatus to 'Odprto' so the
      // local store rehydrates without throwing.
      legalBasis: json['legalBasis'] as String?,
      caseStatus: (json['caseStatus'] as String?) ?? 'Odprto',
      pendingSync: json['pendingSync'] as bool,
      // Absent on every record cached before TB-2; such a record was, by
      // definition, not queued for deletion.
      pendingDelete: (json['pendingDelete'] as bool?) ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      proposedType: json['proposedType'] as String?,
      createdBy: json['createdBy'] as String?,
      obhodId: json['obhodId'] as String?,
      // Absent on records cached before TB-26, and on any record the back
      // office has not reviewed yet -- both read as null.
      reviewedBy: json['reviewedBy'] as String?,
      reviewedAt: json['reviewedAt'] != null
          ? DateTime.parse(json['reviewedAt'] as String)
          : null,
    );
  }

  /// Backwards-compat reader: pre-photo-sync builds wrote `photoPaths` as a
  /// flat list of strings. Anything we read in that shape is treated as
  /// already-uploaded local files (best we can do without re-uploading them
  /// blindly — the user can re-attach if they want them on the server).
  static List<DisturbancePhoto> _readPhotos(Map<String, dynamic> json) {
    final fresh = json['photos'];
    if (fresh is List) {
      return fresh
          .map((entry) => DisturbancePhoto.fromJson(entry as Map<String, dynamic>))
          .toList();
    }
    final legacy = json['photoPaths'];
    if (legacy is List) {
      return legacy.cast<String>().map((path) {
        return DisturbancePhoto(
          id: path,
          mimeType: 'image/jpeg',
          localPath: path,
          pendingUpload: false,
        );
      }).toList();
    }
    return const [];
  }
}
