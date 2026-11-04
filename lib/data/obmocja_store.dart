import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/zos_render_style.dart'
    show parseZosColor;
import 'package:narcis_nadzorniki/data/zos_style_store.dart';
import 'package:vector_tile/vector_tile.dart' as vt;

/// The six "Območja s statusom" (protected-area) sublayers. Each name is the
/// slug narcis-vibed uses: the tileset's source layer and the legend's key.
enum ZosKind { n2k, zo, epo, nv, nvj, mvo }

/// Picker and identify order: the app's original five, then the international
/// designations (the web's toggle order puts them last too).
const List<ZosKind> zosOrder = [
  ZosKind.n2k,
  ZosKind.zo,
  ZosKind.epo,
  ZosKind.nv,
  ZosKind.nvj,
  ZosKind.mvo,
];

/// One protected area under an identify tap: what the tile carries (name,
/// code, class) plus, when the VPS answered, its detail record (TB-47).
class ObmocjeFeature {
  const ObmocjeFeature({
    required this.kind,
    required this.id,
    required this.isPoint,
    required this.ime,
    required this.koda,
    required this.cls,
    required this.color,
    required this.opis,
    required this.rows,
  });

  final ZosKind kind;
  final int id; // NARCIS_ZOS.ID: the tile feature id and the detail key
  final bool isPoint;
  final String ime; // IME_OBM
  final String koda; // KODA_OBM
  final String cls; // `_cls`, the legend key ('' on single-class layers)
  final int? color; // ARGB from the served legend; null when it has none
  final String opis;
  final List<MapEntry<String, String>> rows; // ordered (label, value)

  /// [props] from the tile; [detail] from `/api/layers/detail/<id>`, or null
  /// when that call failed — then the rows fall back to the tile's fields.
  factory ObmocjeFeature.fromTile({
    required ZosKind kind,
    required int id,
    required bool isPoint,
    required Map<String, Object?> props,
    Map<String, dynamic>? detail,
    List<ZosLegendRow> legend = const [],
  }) {
    String s(Object? v) => (v ?? '').toString().trim();
    String d(String key) => s(detail?[key]);
    String either(String detailKey, String tileKey) {
      final v = d(detailKey);
      return v.isNotEmpty ? v : s(props[tileKey]);
    }

    final rows = <MapEntry<String, String>>[];
    void add(String label, String value) {
      if (value.isNotEmpty) rows.add(MapEntry(label, value));
    }

    var opis = d('opis');
    switch (kind) {
      case ZosKind.n2k:
        add('Tip', either('n2k_tip_obmocja', 'N2K_TIP_OBMOCJA'));
        add('Biogeografska regija',
            either('n2k_biogeo_region', 'N2K_BIOGEO_REGION'));
      case ZosKind.zo:
        add('Vrsta', either('zo_vrsta', 'ZO_VRSTA'));
        add('Pomen', either('zo_pomen', 'ZO_POMEN'));
      case ZosKind.epo:
        break;
      case ZosKind.nv:
      case ZosKind.nvj:
        add('Pomen', either('nv_pomen', 'NV_POMEN'));
        add('Zvrst', either('nv_zvrsti', 'NV_ZVRSTI'));
        add('Režim vstopa', d('nv_rezim_vstop'));
        opis = d('nv_kratka_oznaka');
      case ZosKind.mvo:
        add('Status', d('varstveni_status'));
    }
    final ha = detail?['povrsina_ha'];
    if (ha is num) add('Površina', '${ha.toStringAsFixed(1)} ha');
    add('Datum začetka', d('dat_ustan'));

    final cls = s(props['_cls']);
    return ObmocjeFeature(
      kind: kind,
      id: id,
      isPoint: isPoint,
      ime: s(props['IME_OBM']).isNotEmpty ? s(props['IME_OBM']) : d('ime_obm'),
      koda:
          s(props['KODA_OBM']).isNotEmpty ? s(props['KODA_OBM']) : d('koda_obm'),
      cls: cls,
      color: _legendColor(legend, cls),
      opis: opis,
      rows: rows,
    );
  }
}

/// The legend row for [cls] (single-class layers have one row, key null); the
/// first row as a fallback, as the web's `match` falls back to its first class.
int? _legendColor(List<ZosLegendRow> rows, String cls) {
  if (rows.isEmpty) return null;
  final row = rows.firstWhere(
    (r) => r.key == cls || (r.key == null && cls.isEmpty),
    orElse: () => rows.first,
  );
  return parseZosColor(row.color);
}

/// Reads one tile of the VPS tileset; null when the archive has none there.
typedef ZosTileReader = Future<Uint8List?> Function(int z, int x, int y);

/// Zoom the identify reads: the tileset's deepest, where geometry is finest.
const int kZosIdentifyZoom = 15;

/// A feature of a decoded tile that the tap hits.
class ZosTileHit {
  const ZosTileHit({
    required this.kind,
    required this.id,
    required this.isPoint,
    required this.props,
  });

  final ZosKind kind;
  final int id;
  final bool isPoint;
  final Map<String, Object?> props;
}

/// Tap-to-identify from the tileset itself: the z15 tile under the tap (plus
/// a neighbour when the tap is within [bufferRadiusMeters] of its edge), areas
/// by point-in-polygon, points and lines within that radius. Then the detail
/// record of each hit from the VPS register (`/api/layers/detail/<id>`).
class ObmocjaStore {
  ObmocjaStore({http.Client? client, this.origin = kZosOrigin})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String origin;

  static const _timeout = Duration(seconds: 20);

  /// How close a tap must be to a point or line feature, in metres. Drawn on
  /// the map as a matching circle (see `obmocjaBufferCircleLayer`).
  static const double bufferRadiusMeters = 50;

  /// Every area under [tap] in the [active] sublayers (overlap is the norm),
  /// or an empty list when none is hit. Throws [ObmocjaException] when the
  /// tiles cannot be read, so the caller can tell "nothing here" from "no
  /// connection". A failed detail call only leaves that area's rows short.
  Future<List<ObmocjeFeature>> identify(
    LatLng tap,
    Set<ZosKind> active, {
    required ZosTileReader readTile,
    Map<String, List<ZosLegendRow>> legend = const {},
  }) async {
    if (active.isEmpty) return const [];
    final tiles = zosTilesAround(tap, bufferRadiusMeters);
    final List<Uint8List?> bytes;
    try {
      bytes = await Future.wait([
        for (final t in tiles) readTile(kZosIdentifyZoom, t.$1, t.$2),
      ]).timeout(_timeout);
    } catch (e) {
      throw ObmocjaException(cause: e);
    }
    final hits = <int, ZosTileHit>{};
    for (var i = 0; i < tiles.length; i++) {
      final b = bytes[i];
      if (b == null) continue;
      for (final h in zosHitTest(
          b, tiles[i].$1, tiles[i].$2, tap, active, bufferRadiusMeters)) {
        hits.putIfAbsent(h.id, () => h); // an area spans tiles: one entry
      }
    }
    final ordered = hits.values.toList()
      ..sort((a, b) => zosOrder.indexOf(a.kind) - zosOrder.indexOf(b.kind));
    final details = await Future.wait(ordered.map((h) => _detail(h.id)));
    return [
      for (var i = 0; i < ordered.length; i++)
        ObmocjeFeature.fromTile(
          kind: ordered[i].kind,
          id: ordered[i].id,
          isPoint: ordered[i].isPoint,
          props: ordered[i].props,
          detail: details[i],
          legend: legend[ordered[i].kind.name] ?? const [],
        ),
    ];
  }

  Future<Map<String, dynamic>?> _detail(int id) async {
    try {
      final res = await _client
          .get(Uri.parse('$origin/api/layers/detail/$id'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}

/// World position of [p] at [z] in tile units (Web Mercator).
(double, double) _world(LatLng p, int z) {
  final n = (1 << z).toDouble();
  final lr = p.latitude * math.pi / 180;
  return (
    (p.longitude + 180) / 360 * n,
    (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * n,
  );
}

/// Ground metres per tile at [p]'s latitude and zoom [z].
double _tileMeters(LatLng p, int z) =>
    40075016.686 * math.cos(p.latitude * math.pi / 180) / (1 << z);

/// The z15 tiles to read for a tap: its own, plus each neighbour whose edge
/// is within [radiusM] of it (a point just across the edge is in the
/// neighbour's tile only).
List<(int, int)> zosTilesAround(LatLng tap, double radiusM) {
  final (wx, wy) = _world(tap, kZosIdentifyZoom);
  final tx = wx.floor(), ty = wy.floor();
  final tol = radiusM / _tileMeters(tap, kZosIdentifyZoom);
  final fx = wx - tx, fy = wy - ty;
  final dxs = [0, if (fx < tol) -1, if (fx > 1 - tol) 1];
  final dys = [0, if (fy < tol) -1, if (fy > 1 - tol) 1];
  return [
    for (final dy in dys)
      for (final dx in dxs) (tx + dx, ty + dy),
  ];
}

/// The features of one decoded tile ([tx], [ty] at z15) in [active] layers
/// that [tap] hits: polygons containing it, points and lines within [radiusM].
List<ZosTileHit> zosHitTest(
  Uint8List bytes,
  int tx,
  int ty,
  LatLng tap,
  Set<ZosKind> active,
  double radiusM,
) {
  final tile = vt.VectorTile.fromBytes(bytes: bytes);
  final (wx, wy) = _world(tap, kZosIdentifyZoom);
  final metres = _tileMeters(tap, kZosIdentifyZoom);
  final out = <ZosTileHit>[];
  for (final layer in tile.layers) {
    final kind = ZosKind.values.where((k) => k.name == layer.name).firstOrNull;
    if (kind == null || !active.contains(kind)) continue;
    final ext = layer.extent.toDouble();
    final x = (wx - tx) * ext, y = (wy - ty) * ext;
    final tol = radiusM / metres * ext;
    for (final f in layer.features) {
      final g = f.decodeGeometry();
      final bool hit;
      var isPoint = false;
      switch (g) {
        case vt.GeometryPoint(:final coordinates):
          isPoint = true;
          hit = _near(x, y, coordinates, tol);
        case vt.GeometryMultiPoint(:final coordinates):
          isPoint = true;
          hit = coordinates.any((c) => _near(x, y, c, tol));
        case vt.GeometryLineString(:final coordinates):
          hit = _nearLine(x, y, coordinates, tol);
        case vt.GeometryMultiLineString(:final coordinates):
          hit = coordinates.any((l) => _nearLine(x, y, l, tol));
        case vt.GeometryPolygon(:final coordinates):
          hit = _inPolygon(x, y, coordinates);
        case vt.GeometryMultiPolygon(:final coordinates):
          hit = (coordinates ?? const []).any((p) => _inPolygon(x, y, p));
        default:
          hit = false;
      }
      if (!hit) continue;
      out.add(ZosTileHit(
        kind: kind,
        id: f.id.toInt(),
        isPoint: isPoint,
        props: {
          for (final e in f.decodeProperties().entries)
            e.key: e.value.dartStringValue ??
                e.value.dartIntValue?.toInt() ??
                e.value.dartDoubleValue ??
                e.value.dartBoolValue,
        },
      ));
    }
  }
  return out;
}

bool _near(double x, double y, List<double> c, double tol) =>
    (c[0] - x) * (c[0] - x) + (c[1] - y) * (c[1] - y) <= tol * tol;

bool _nearLine(double x, double y, List<List<double>> line, double tol) {
  for (var i = 1; i < line.length; i++) {
    final (ax, ay, bx, by) = (line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0
        ? 0.0
        : (((x - ax) * dx + (y - ay) * dy) / len2).clamp(0.0, 1.0);
    if (_near(x, y, [ax + t * dx, ay + t * dy], tol)) return true;
  }
  return false;
}

/// Even-odd over every ring, so holes subtract.
bool _inPolygon(double x, double y, List<List<List<double>>> rings) {
  var inside = false;
  for (final r in rings) {
    for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
      if ((r[i][1] > y) != (r[j][1] > y) &&
          x <
              (r[j][0] - r[i][0]) * (y - r[i][1]) / (r[j][1] - r[i][1]) +
                  r[i][0]) {
        inside = !inside;
      }
    }
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
