import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// One protected area returned by a WMS GetFeatureInfo "identify" at a tapped
/// point. Every field comes from that single GeoServer call — there is no
/// separate detail fetch.
class ObmocjeFeature {
  const ObmocjeFeature({
    required this.ime,
    required this.koda,
    required this.tip,
    required this.opis,
    required this.biogeoRegion,
    required this.povrsinaHa,
    required this.datZac,
  });

  final String ime; // IME_OBM — area name
  final String koda; // KODA_OBM — Natura code (SI5… = POV/SPA, SI3… = POO/SAC)
  final String tip; // N2K_TIP_OBMOCJA — POV (SPA) / POO (SAC)
  final String opis; // OPIS — description
  final String biogeoRegion; // N2K_BIOGEO_REGION
  final double? povrsinaHa; // POV_HA — area in hectares
  final String datZac; // DAT_ZAC — start date (ISO yyyy-mm-dd)

  bool get isPov => tip.toUpperCase().startsWith('POV');

  factory ObmocjeFeature.fromProperties(Map<String, dynamic> p) {
    double? ha;
    final raw = p['POV_HA'];
    if (raw is num) {
      ha = raw.toDouble();
    } else if (raw is String) {
      ha = double.tryParse(raw);
    }
    final dat = (p['DAT_ZAC'] ?? '').toString();
    return ObmocjeFeature(
      ime: (p['IME_OBM'] ?? '').toString(),
      koda: (p['KODA_OBM'] ?? '').toString(),
      tip: (p['N2K_TIP_OBMOCJA'] ?? '').toString(),
      opis: (p['OPIS'] ?? '').toString(),
      biogeoRegion: (p['N2K_BIOGEO_REGION'] ?? '').toString(),
      povrsinaHa: ha,
      datZac: dat.length >= 10 ? dat.substring(0, 10) : dat, // trim ISO time
    );
  }
}

/// Tap-to-identify against the production NarcIS GeoServer (public WMS, no
/// auth). The map renders the Natura 2000 layer as server-styled WMS tiles
/// (see `obmocjaWmsLayers` in widgets/basemap.dart); this class only handles
/// the identify, whose response also carries every attribute the detail sheet
/// shows. No layer download, no client reprojection — the 20 s live-ORDS path
/// is gone.
///
/// Layer: `SI.NARCIS:ZOS_N2K_PLG` ("Območja s statusom" → Natura 2000) on
/// `narcis.gov.si/ows`. The same WMS serves the other ZOS layers (EPO/NV/jame)
/// when we add them.
class ObmocjaStore {
  ObmocjaStore({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _owsBase = 'https://narcis.gov.si/ows/ows';
  static const _n2kLayer = 'SI.NARCIS:ZOS_N2K_PLG';
  static const _timeout = Duration(seconds: 20);

  /// GetFeatureInfo at [tap]: returns every Natura 2000 area under the point
  /// (overlap is common), or an empty list if the point is on no area. Throws
  /// [ObmocjaException] on a network/HTTP failure so the caller can distinguish
  /// "nothing here" from "no connection".
  ///
  /// A small bbox around the tap is queried at its centre pixel, with a pixel
  /// BUFFER for finger-tap tolerance, in EPSG:4326 (WMS 1.3.0 lat,lon order) —
  /// so no client-side reprojection is needed.
  Future<List<ObmocjeFeature>> identify(LatLng tap) async {
    const d = 0.0020; // ~±220 m bbox half-size
    const px = 256;
    final bbox = '${tap.latitude - d},${tap.longitude - d},'
        '${tap.latitude + d},${tap.longitude + d}';
    final uri = Uri.parse(_owsBase).replace(queryParameters: {
      'SERVICE': 'WMS',
      'VERSION': '1.3.0',
      'REQUEST': 'GetFeatureInfo',
      'LAYERS': _n2kLayer,
      'QUERY_LAYERS': _n2kLayer,
      'CRS': 'EPSG:4326',
      'BBOX': bbox,
      'WIDTH': '$px',
      'HEIGHT': '$px',
      'I': '${px ~/ 2}',
      'J': '${px ~/ 2}',
      'INFO_FORMAT': 'application/json',
      'FEATURE_COUNT': '10',
      'BUFFER': '12',
    });
    final http.Response res;
    try {
      res = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      throw ObmocjaException(cause: e);
    }
    if (res.statusCode != 200) {
      throw ObmocjaException(statusCode: res.statusCode, body: res.body);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final feats = (j is Map) ? j['features'] : null;
    if (feats is! List) return const [];
    final out = <ObmocjeFeature>[];
    for (final f in feats) {
      if (f is Map && f['properties'] is Map) {
        out.add(ObmocjeFeature.fromProperties(
          (f['properties'] as Map).cast<String, dynamic>(),
        ));
      }
    }
    return out;
  }
}

class ObmocjaException implements Exception {
  ObmocjaException({this.statusCode, this.body, this.cause});

  final int? statusCode;
  final String? body;
  final Object? cause;

  @override
  String toString() => 'ObmocjaException($statusCode): ${body ?? cause}';
}
