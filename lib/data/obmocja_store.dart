import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

/// One polygon part: an outer ring plus any holes. A GeoJSON `Polygon` yields
/// one part; a `MultiPolygon` yields several. Coordinates are already WGS84
/// (reprojected from the source EPSG:3794 at load time).
class N2kPart {
  const N2kPart({required this.outer, this.holes = const []});

  final List<LatLng> outer;
  final List<List<LatLng>> holes;
}

/// A Natura 2000 area ("Območje s statusom", tip `N2k`). [tip] is the
/// designation: `POV` (SPA — birds directive) or `POO` (SAC — habitats).
class N2kArea {
  const N2kArea({
    required this.id,
    required this.ime,
    required this.koda,
    required this.tip,
    required this.parts,
    this.point,
  });

  final int id;
  final String ime; // IME_OBM — area name
  final String koda; // KODA_OBM — Natura code, e.g. SI3000006
  final String tip; // POV or POO
  final List<N2kPart> parts;
  final LatLng? point; // set only for the rare Point-geometry feature

  bool get isPov => tip.toUpperCase().startsWith('POV');
}

/// Extra attributes for the tap-for-detail sheet, from `/vib/zos-detail/:id`.
class ObmocjeDetail {
  const ObmocjeDetail({
    required this.varstveniStatus,
    required this.tipObmocja,
    required this.biogeoRegion,
    required this.opis,
    required this.povrsinaHa,
    required this.datUstan,
  });

  final String varstveniStatus; // "Natura 2000"
  final String tipObmocja; // "POO (SAC)" / "POV (SPA)"
  final String biogeoRegion; // "alpska" / "celinska"
  final String opis; // free-text description
  final double? povrsinaHa; // area in hectares
  final String datUstan; // date established (ISO yyyy-mm-dd)

  factory ObmocjeDetail.fromJson(Map<String, dynamic> j) {
    double? ha;
    final raw = j['povrsina_ha'];
    if (raw is num) {
      ha = raw.toDouble();
    } else if (raw is String) {
      ha = double.tryParse(raw);
    }
    return ObmocjeDetail(
      varstveniStatus: (j['varstveni_status'] ?? '').toString(),
      tipObmocja: (j['n2k_tip_obmocja'] ?? '').toString(),
      biogeoRegion: (j['n2k_biogeo_region'] ?? '').toString(),
      opis: (j['opis'] ?? '').toString(),
      povrsinaHa: ha,
      datUstan: (j['dat_ustan'] ?? '').toString(),
    );
  }
}

/// Loads and caches the Natura 2000 ("Območja") overlay from the public NarcIS
/// ORDS GIS modules on `narcis.gov.si`.
///
/// The geometry endpoint returns GeoJSON in EPSG:3794 (Slovene national grid)
/// wrapped in an ORDS `{items:[{geojson: "<stringified FeatureCollection>"}]}`
/// envelope; we unwrap, parse, and reproject to WGS84 for flutter_map.
///
/// Single-host by design: the field app talks only to `narcis.gov.si`, the same
/// authoritative host as its disturbance/walk data. These modules are public
/// (no `X-Narcis-Auth`).
class ObmocjaStore {
  ObmocjaStore({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _zosBase = 'https://narcis.gov.si/ords/narcis/vib/zos';
  static const _detailBase = 'https://narcis.gov.si/ords/narcis/vib/zos-detail';
  static const _timeout = Duration(seconds: 30);

  // Source projection: Slovenia 1996 / Slovene National Grid (EPSG:3794) — the
  // same proj string narcis-vibed uses. WGS84 (EPSG:4326) is built into
  // proj4dart. `get ?? add` keeps re-registration safe across hot reloads.
  static final proj4.Projection _src = proj4.Projection.get('EPSG:3794') ??
      proj4.Projection.add(
        'EPSG:3794',
        '+proj=tmerc +lat_0=0 +lon_0=15 +k=0.9999 +x_0=500000 +y_0=-5000000 '
        '+ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs',
      );
  static final proj4.Projection _dst = proj4.Projection.get('EPSG:4326')!;

  // N2k is national and static, so one fetch per app session is plenty. The
  // parsed result is cached on the instance; HomeScreen keeps a single store.
  List<N2kArea>? _cache;

  bool get isLoaded => _cache != null;
  List<N2kArea> get areas => _cache ?? const [];

  /// Fetches + parses the N2k layer once; returns the cache on later calls.
  Future<List<N2kArea>> loadN2k() async {
    final cached = _cache;
    if (cached != null) return cached;
    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$_zosBase/N2k')).timeout(_timeout);
    } catch (e) {
      throw ObmocjaException(cause: e);
    }
    if (res.statusCode != 200) {
      throw ObmocjaException(statusCode: res.statusCode, body: res.body);
    }
    final parsed = _parseEnvelope(res.bodyBytes);
    _cache = parsed;
    return parsed;
  }

  /// Fetches the attribute detail for one area. Returns null on any failure so
  /// the sheet can fall back to the inline name/code/tip already in hand.
  Future<ObmocjeDetail?> loadDetail(int id) async {
    try {
      final res =
          await _client.get(Uri.parse('$_detailBase/$id')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final outer = jsonDecode(utf8.decode(res.bodyBytes));
      final items = (outer is Map) ? outer['items'] : null;
      if (items is! List || items.isEmpty) return null;
      final detailStr = (items.first as Map)['detail'];
      if (detailStr is! String) return null;
      final j = jsonDecode(detailStr);
      if (j is! Map<String, dynamic>) return null;
      return ObmocjeDetail.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  List<N2kArea> _parseEnvelope(List<int> bytes) {
    final outer = jsonDecode(utf8.decode(bytes));
    final items = (outer is Map) ? outer['items'] : null;
    if (items is! List || items.isEmpty) {
      throw ObmocjaException(body: 'unexpected ORDS envelope');
    }
    final geojsonStr = (items.first as Map)['geojson'];
    if (geojsonStr is! String) {
      throw ObmocjaException(body: 'missing geojson in envelope');
    }
    final fc = jsonDecode(geojsonStr);
    final feats = (fc is Map) ? fc['features'] : null;
    if (feats is! List) throw ObmocjaException(body: 'missing features');
    final out = <N2kArea>[];
    for (final f in feats) {
      final area = _parseFeature(f);
      if (area != null) out.add(area);
    }
    return out;
  }

  N2kArea? _parseFeature(dynamic f) {
    if (f is! Map) return null;
    final geom = f['geometry'] as Map?;
    if (geom == null) return null;
    final props = (f['properties'] as Map?) ?? const {};
    final id =
        (f['id'] is int) ? f['id'] as int : int.tryParse('${f['id']}') ?? -1;
    final tip = (props['N2K_TIP_OBMOCJA'] ?? props['_cls'] ?? '').toString();
    final ime = (props['IME_OBM'] ?? '').toString();
    final koda = (props['KODA_OBM'] ?? '').toString();
    final coords = geom['coordinates'];
    final parts = <N2kPart>[];
    LatLng? point;
    switch (geom['type']) {
      case 'Polygon':
        final p = _parsePolygon(coords);
        if (p != null) parts.add(p);
        break;
      case 'MultiPolygon':
        if (coords is List) {
          for (final poly in coords) {
            final p = _parsePolygon(poly);
            if (p != null) parts.add(p);
          }
        }
        break;
      case 'Point':
        point = _projectPair(coords);
        break;
      default:
        return null;
    }
    if (parts.isEmpty && point == null) return null;
    return N2kArea(
      id: id,
      ime: ime,
      koda: koda,
      tip: tip,
      parts: parts,
      point: point,
    );
  }

  N2kPart? _parsePolygon(dynamic rings) {
    if (rings is! List || rings.isEmpty) return null;
    final outer = _projectRing(rings.first);
    if (outer.length < 3) return null;
    final holes = <List<LatLng>>[];
    for (var i = 1; i < rings.length; i++) {
      final h = _projectRing(rings[i]);
      if (h.length >= 3) holes.add(h);
    }
    return N2kPart(outer: outer, holes: holes);
  }

  List<LatLng> _projectRing(dynamic ring) {
    final out = <LatLng>[];
    if (ring is! List) return out;
    for (final pair in ring) {
      final ll = _projectPair(pair);
      if (ll != null) out.add(ll);
    }
    return out;
  }

  LatLng? _projectPair(dynamic pair) {
    if (pair is! List || pair.length < 2) return null;
    final x = (pair[0] as num).toDouble();
    final y = (pair[1] as num).toDouble();
    final p = _src.transform(_dst, proj4.Point(x: x, y: y));
    return LatLng(p.y, p.x); // proj4 returns x=lon, y=lat for EPSG:4326
  }
}

/// Returns the first area whose outer ring contains [tap], or null. Holes are
/// ignored (a tap inside a hole still matches the enclosing area) — an
/// acceptable approximation for tap-to-identify. O(features × vertices), run
/// only on tap, never per frame.
N2kArea? areaAtPoint(List<N2kArea> areas, LatLng tap) {
  for (final a in areas) {
    for (final part in a.parts) {
      if (_ringContains(part.outer, tap)) return a;
    }
  }
  return null;
}

/// Even-odd ray casting in lat/lng space. Adequate at Slovenia's scale; this is
/// a tap hit-test, not geodesic point-in-polygon.
bool _ringContains(List<LatLng> ring, LatLng p) {
  var inside = false;
  final n = ring.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

class ObmocjaException implements Exception {
  ObmocjaException({this.statusCode, this.body, this.cause});

  final int? statusCode;
  final String? body;
  final Object? cause;

  @override
  String toString() => 'ObmocjaException($statusCode): ${body ?? cause}';
}
