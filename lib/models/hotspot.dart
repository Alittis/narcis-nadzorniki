/// TB-39 phase 1 (narcis-vibed NV-622): a hot spot (*vroča točka*), a
/// permanent named point of the user's org where wardens file a new record on
/// each visit. Created on the desktop by the org admin; read-only on the phone,
/// which lists them (`GET hotspots`) and may attach a NEW record to one.
class Hotspot {
  const Hotspot({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
      };

  /// One entry of the `hotspots` list, or of the local cache. The server sends
  /// absent-on-null, so an entry without a name or a coordinate cannot be drawn
  /// and reads as null; the caller skips it.
  static Hotspot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final lat = raw['latitude'];
    final lon = raw['longitude'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || lat is! num || lon is! num) return null;
    return Hotspot(
      id: id,
      name: name,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
    );
  }

  /// [tryFromJson] over a list, dropping what it cannot read.
  static List<Hotspot> listFromJson(Object? raw) => raw is List
      ? [
          for (final e in raw)
            if (tryFromJson(e) case final Hotspot h) h,
        ]
      : const [];
}
