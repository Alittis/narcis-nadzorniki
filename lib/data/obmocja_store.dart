import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// The five "Območja s statusom" (protected-area) sublayers, matching the
/// narcis-vibed web app.
enum ZosKind { n2k, zo, epo, nv, nvj }

/// Canonical order — used for the picker, for stacking WMS layers (earlier =
/// drawn lower), and for identify. Polygon-heavy layers first, cave points last.
const List<ZosKind> zosOrder = [
  ZosKind.n2k,
  ZosKind.zo,
  ZosKind.epo,
  ZosKind.nv,
  ZosKind.nvj,
];

/// GeoServer WMS layer name(s) per sublayer (workspace `SI.NARCIS` on
/// `narcis.gov.si/ows`). Polygons listed before points so points draw on top.
const Map<ZosKind, List<String>> zosWmsLayers = {
  ZosKind.n2k: ['SI.NARCIS:ZOS_N2K_PLG'],
  ZosKind.zo: ['SI.NARCIS:ZOS_ZO_PLG', 'SI.NARCIS:ZOS_ZO_PNT'],
  ZosKind.epo: ['SI.NARCIS:ZOS_EPO_PLG', 'SI.NARCIS:ZOS_EPO_PNT'],
  ZosKind.nv: ['SI.NARCIS:ZOS_NV_PLG', 'SI.NARCIS:ZOS_NV_PNT'],
  ZosKind.nvj: ['SI.NARCIS:ZOS_NV_PNT_JAME'],
};

/// Maps a GetFeatureInfo feature id (e.g. `ZOS_NV_PNT_JAME.42`) back to its
/// sublayer. Order matters: the jame prefix is a superset-prefix of NV.
ZosKind? zosKindFromFeatureId(String id) {
  if (id.contains('ZOS_NV_PNT_JAME')) return ZosKind.nvj;
  if (id.contains('ZOS_N2K')) return ZosKind.n2k;
  if (id.contains('ZOS_ZO')) return ZosKind.zo;
  if (id.contains('ZOS_EPO')) return ZosKind.epo;
  if (id.contains('ZOS_NV')) return ZosKind.nv;
  return null;
}

/// One protected area returned by a WMS GetFeatureInfo "identify". Attributes
/// differ per sublayer, so the per-kind detail rows are pre-built into [rows];
/// [ime]/[koda]/[opis] are the fields common enough to surface directly.
class ObmocjeFeature {
  const ObmocjeFeature({
    required this.kind,
    required this.isPoint,
    required this.ime,
    required this.koda,
    required this.tip,
    required this.vrsta,
    required this.pomen,
    required this.status,
    required this.opis,
    required this.rows,
  });

  final ZosKind kind;
  final bool isPoint; // point feature (from a _PNT sublayer) vs polygon (_PLG)
  final String ime; // IME_OBM
  final String koda; // KODA_OBM
  final String tip; // N2K_TIP_OBMOCJA (POV/POO) — '' for non-N2k kinds
  final String vrsta; // ZO_VRSTA — '' for non-ZO; keys the ZO symbol colour
  final String pomen; // NV_POMEN (državni/lokalni) — '' for non-NV
  final String status; // NV_STATUS ('OP' ⇒ outline-only) — '' unless NV
  final String opis; // description (OPIS / NV_KRATKA_OZNAKA / '')
  final List<MapEntry<String, String>> rows; // ordered (label, value) details

  factory ObmocjeFeature.fromProperties(
    ZosKind kind,
    bool isPoint,
    Map<String, dynamic> p,
  ) {
    String s(String k) => (p[k] ?? '').toString().trim();
    String date(String k) {
      final v = s(k);
      return v.length >= 10 ? v.substring(0, 10) : v; // trim ISO time
    }

    String area() {
      final r = p['POV_HA'];
      final ha = r is num ? r.toDouble() : (r is String ? double.tryParse(r) : null);
      return ha == null ? '' : '${ha.toStringAsFixed(1)} ha';
    }

    final rows = <MapEntry<String, String>>[];
    void add(String label, String value) {
      if (value.isNotEmpty) rows.add(MapEntry(label, value));
    }

    var opis = '';
    switch (kind) {
      case ZosKind.n2k:
        add('Tip', s('N2K_TIP_OBMOCJA'));
        add('Biogeografska regija', s('N2K_BIOGEO_REGION'));
        opis = s('OPIS');
        break;
      case ZosKind.zo:
        add('Vrsta', s('ZO_VRSTA'));
        add('Pomen', s('ZO_POMEN'));
        add('Predpis', s('CITAT'));
        break;
      case ZosKind.epo:
        opis = s('OPIS');
        break;
      case ZosKind.nv:
      case ZosKind.nvj:
        add('Pomen', s('NV_POMEN'));
        add('Zvrst', s('NV_ZVRSTI'));
        opis = s('NV_KRATKA_OZNAKA');
        break;
    }
    add('Površina', area());
    add('Datum začetka', date('DAT_ZAC'));

    return ObmocjeFeature(
      kind: kind,
      isPoint: isPoint,
      ime: s('IME_OBM'),
      koda: s('KODA_OBM'),
      tip: s('N2K_TIP_OBMOCJA'),
      vrsta: s('ZO_VRSTA'),
      pomen: s('NV_POMEN'),
      status: s('NV_STATUS'),
      opis: opis,
      rows: rows,
    );
  }
}

/// Tap-to-identify against the production NarcIS GeoServer (public WMS, no auth
/// for the ZOS layers). The map renders the toggled sublayers as server-styled
/// WMS tiles (see `obmocjaWmsLayers` in widgets/basemap.dart); this class only
/// handles the identify, whose response also carries every attribute the detail
/// sheet shows. No layer download, no client reprojection.
class ObmocjaStore {
  ObmocjaStore({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _owsBase = 'https://narcis.gov.si/ows/ows';
  static const _timeout = Duration(seconds: 20);

  // Identify query grid: a ground-square bbox of half-extent _halfM metres,
  // sampled at _px×_px and queried at the centre pixel with a _bufferPx search
  // radius. Ground resolution is 2·_halfM/_px ≈ 1.7 m/px, so the buffer is
  // ~50 m on the ground — wide enough to pick point features (caves, NV/EPO
  // points) with a finger, without grabbing unrelated areas.
  static const _halfM = 220.0;
  static const _px = 256;
  static const _bufferPx = 30;

  /// Ground radius (metres) of the identify tap buffer. Drawn on the map as a
  /// matching circle (see `obmocjaBufferCircleLayer`).
  static const double bufferRadiusMeters = _bufferPx * 2 * _halfM / _px;

  /// GetFeatureInfo at [tap] across the [active] sublayers. Returns every area
  /// under the point (overlap is the norm), tagged with its [ZosKind], or an
  /// empty list if none are active / nothing is hit. Throws [ObmocjaException]
  /// on a network/HTTP failure so the caller can distinguish "nothing here"
  /// from "no connection".
  ///
  /// Small bbox around the tap, centre pixel + a generous pixel BUFFER (~50 m
  /// on the ground, so point features are easy to tap), EPSG:4326 (WMS 1.3.0
  /// lat,lon order) — no client reprojection.
  Future<List<ObmocjeFeature>> identify(LatLng tap, Set<ZosKind> active) async {
    final names = <String>[];
    for (final k in zosOrder) {
      if (active.contains(k)) names.addAll(zosWmsLayers[k]!);
    }
    if (names.isEmpty) return const [];
    final layers = names.join(',');

    // Ground-square bbox: widen the longitude extent by 1/cos(lat) so a metre
    // is a metre in both axes, making the pixel buffer a true circle on the
    // ground (and matching the drawn buffer circle).
    final dLat = _halfM / 111320.0;
    final dLon = _halfM / (111320.0 * math.cos(tap.latitude * math.pi / 180.0));
    final bbox = '${tap.latitude - dLat},${tap.longitude - dLon},'
        '${tap.latitude + dLat},${tap.longitude + dLon}';
    final uri = Uri.parse(_owsBase).replace(queryParameters: {
      'SERVICE': 'WMS',
      'VERSION': '1.3.0',
      'REQUEST': 'GetFeatureInfo',
      'LAYERS': layers,
      'QUERY_LAYERS': layers,
      'CRS': 'EPSG:4326',
      'BBOX': bbox,
      'WIDTH': '$_px',
      'HEIGHT': '$_px',
      'I': '${_px ~/ 2}',
      'J': '${_px ~/ 2}',
      'INFO_FORMAT': 'application/json',
      'FEATURE_COUNT': '30',
      'BUFFER': '$_bufferPx',
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
      if (f is! Map || f['properties'] is! Map) continue;
      final id = '${f['id']}';
      final kind = zosKindFromFeatureId(id);
      if (kind == null) continue;
      out.add(ObmocjeFeature.fromProperties(
        kind,
        id.contains('_PNT'),
        (f['properties'] as Map).cast<String, dynamic>(),
      ));
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
