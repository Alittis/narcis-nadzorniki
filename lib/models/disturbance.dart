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
    required this.photoPaths,
    required this.observers,
    required this.actionTaken,
    required this.pendingSync,
    required this.createdAt,
    this.proposedType,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String locationAccuracy;
  final DateTime observedAt;
  final List<SelectedDisturbanceType> types;
  final String description;
  final List<String> photoPaths;
  final List<String> observers;
  final String actionTaken;
  final bool pendingSync;
  final DateTime createdAt;
  final String? proposedType;

  Disturbance copyWith({
    double? latitude,
    double? longitude,
    String? locationAccuracy,
    DateTime? observedAt,
    List<SelectedDisturbanceType>? types,
    String? description,
    List<String>? photoPaths,
    List<String>? observers,
    String? actionTaken,
    bool? pendingSync,
    DateTime? createdAt,
    String? proposedType,
  }) {
    return Disturbance(
      id: id,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationAccuracy: locationAccuracy ?? this.locationAccuracy,
      observedAt: observedAt ?? this.observedAt,
      types: types ?? this.types,
      description: description ?? this.description,
      photoPaths: photoPaths ?? this.photoPaths,
      observers: observers ?? this.observers,
      actionTaken: actionTaken ?? this.actionTaken,
      pendingSync: pendingSync ?? this.pendingSync,
      createdAt: createdAt ?? this.createdAt,
      proposedType: proposedType ?? this.proposedType,
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
        'photoPaths': photoPaths,
        'observers': observers,
        'actionTaken': actionTaken,
        'pendingSync': pendingSync,
        'createdAt': createdAt.toIso8601String(),
        'proposedType': proposedType,
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
      photoPaths: (json['photoPaths'] as List<dynamic>).cast<String>(),
      observers: (json['observers'] as List<dynamic>).cast<String>(),
      actionTaken: json['actionTaken'] as String,
      pendingSync: json['pendingSync'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      proposedType: json['proposedType'] as String?,
    );
  }
}
