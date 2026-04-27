import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

class MapViewport {
  const MapViewport({required this.center, required this.zoom});

  final LatLng center;
  final double zoom;

  Map<String, dynamic> toJson() => {
        'lat': center.latitude,
        'lon': center.longitude,
        'zoom': zoom,
      };

  static MapViewport? fromJson(Map<String, dynamic> json) {
    final lat = (json['lat'] as num?)?.toDouble();
    final lon = (json['lon'] as num?)?.toDouble();
    final zoom = (json['zoom'] as num?)?.toDouble();
    if (lat == null || lon == null || zoom == null) return null;
    return MapViewport(center: LatLng(lat, lon), zoom: zoom);
  }
}

class MapViewStore {
  static const _fileName = 'map_view.json';

  Future<File> _file() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_fileName');
  }

  Future<MapViewport?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      return MapViewport.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MapViewport viewport) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(viewport.toJson()));
    } catch (_) {
      // Best-effort cache; failure is non-fatal.
    }
  }
}
