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
    required this.pendingSync,
    required this.createdAt,
    this.proposedType,
    this.createdBy,
    this.obhodId,
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
  final bool pendingSync;
  final DateTime createdAt;
  final String? proposedType;
  // Email of the user who created the record. Null for local-only records
  // that haven't been pushed yet (the caller is the author by definition);
  // populated from `ustvarjen_od` when pulled from the server.
  final String? createdBy;
  // Walk-around (obhod) the record was captured during. Stamped in
  // `AppState.addRecord` when a walk is active; null otherwise.
  final String? obhodId;

  bool get hasPendingPhotoUploads => photos.any((p) => p.pendingUpload);

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
    bool? pendingSync,
    DateTime? createdAt,
    String? proposedType,
    String? createdBy,
    String? obhodId,
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
      pendingSync: pendingSync ?? this.pendingSync,
      createdAt: createdAt ?? this.createdAt,
      proposedType: proposedType ?? this.proposedType,
      createdBy: createdBy ?? this.createdBy,
      obhodId: obhodId ?? this.obhodId,
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
        'pendingSync': pendingSync,
        'createdAt': createdAt.toIso8601String(),
        'proposedType': proposedType,
        'createdBy': createdBy,
        'obhodId': obhodId,
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
      pendingSync: json['pendingSync'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      proposedType: json['proposedType'] as String?,
      createdBy: json['createdBy'] as String?,
      obhodId: json['obhodId'] as String?,
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
