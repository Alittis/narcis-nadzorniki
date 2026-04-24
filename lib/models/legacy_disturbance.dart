class LegacyDisturbance {
  const LegacyDisturbance({
    required this.sourceId,
    required this.observedAt,
    required this.observer,
    required this.latitude,
    required this.longitude,
    required this.locationSource,
    required this.locationAccuracy,
    required this.plusCode,
    required this.description,
    required this.photoUrls,
    required this.categoriesByGroup,
    required this.actionTaken,
  });

  final String? sourceId;
  final DateTime? observedAt;
  final String? observer;
  final double latitude;
  final double longitude;
  final String? locationSource;
  final String? locationAccuracy;
  final String? plusCode;
  final String? description;
  final List<String> photoUrls;
  final Map<String, List<String>> categoriesByGroup;
  final String? actionTaken;

  factory LegacyDisturbance.fromJson(Map<String, dynamic> json) {
    return LegacyDisturbance(
      sourceId: json['sourceId'] as String?,
      observedAt: json['observedAt'] == null
          ? null
          : DateTime.tryParse(json['observedAt'] as String),
      observer: json['observer'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      locationSource: json['locationSource'] as String?,
      locationAccuracy: json['locationAccuracy'] as String?,
      plusCode: json['plusCode'] as String?,
      description: json['description'] as String?,
      photoUrls:
          (json['photoUrls'] as List<dynamic>? ?? const []).cast<String>(),
      categoriesByGroup: (json['categoriesByGroup'] as Map<String, dynamic>? ?? const {})
          .map((key, value) => MapEntry(key, (value as List<dynamic>).cast<String>())),
      actionTaken: json['actionTaken'] as String?,
    );
  }
}
