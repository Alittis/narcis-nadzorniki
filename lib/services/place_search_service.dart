import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class PlaceResult {
  PlaceResult({
    required this.displayName,
    required this.location,
  });

  final String displayName;
  final LatLng location;
}

class PlaceSearchService {
  PlaceSearchService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _endpoint = 'https://nominatim.openstreetmap.org/search';
  // Nominatim usage policy requires an identifying User-Agent.
  static const _userAgent = 'si.narcis.nadzorniki/1.0';

  Future<List<PlaceResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'q': trimmed,
      'format': 'jsonv2',
      'limit': '8',
      'accept-language': 'sl',
    });

    final response = await _client.get(
      uri,
      headers: {'User-Agent': _userAgent},
    );
    if (response.statusCode != 200) {
      return const [];
    }
    final data = jsonDecode(response.body);
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map((row) {
          final lat = double.tryParse('${row['lat']}');
          final lon = double.tryParse('${row['lon']}');
          final name = row['display_name'] as String?;
          if (lat == null || lon == null || name == null) return null;
          return PlaceResult(
            displayName: name,
            location: LatLng(lat, lon),
          );
        })
        .whereType<PlaceResult>()
        .toList(growable: false);
  }
}
