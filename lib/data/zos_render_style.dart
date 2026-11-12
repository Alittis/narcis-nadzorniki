import 'dart:convert';

/// Bump whenever [zosRenderStyle] or the circle sprites' drawing changes: the
/// map's cached raster tiles are keyed on the theme version, which carries it.
/// 3: TB-37 took the natural monuments out of the `zo` set.
const int kZosRendererRevision = 3;

/// TB-37: natural monuments are shown and hidden on their own. They are one
/// class (`_cls`) of the ZO source layer, so the phone's [kZosMonumentSlug]
/// sublayer draws from `zo`, and `zo` on its own leaves them out.
const String kZosMonumentSlug = 'ns';

/// The ZO `_cls` of a natural monument (*naravni spomenik*). Not *spomenik
/// oblikovane narave*, which is a class of its own and stays with ZO.
const String kZoMonumentClass = 'naravni-spomenik';

/// A dot standing in for one colour of a MapLibre `circle` layer, drawn as
/// MapLibre does: [color] fill of [radius], with a [strokeWidth] ring of
/// [strokeColor] outside it. Sizes are logical pixels; colours ARGB.
class ZosCircleSprite {
  const ZosCircleSprite({
    required this.name,
    required this.radius,
    required this.color,
    required this.strokeColor,
    required this.strokeWidth,
  });

  final String name;
  final double radius;
  final int color;
  final int strokeColor;
  final double strokeWidth;

  /// Logical width and height of the sprite: the dot, its ring, 1 px margin.
  double get size => 2 * (radius + strokeWidth) + 2;
}

/// The served style turned into what `vector_tile_renderer` 6.1.0 can draw.
class ZosRenderStyle {
  const ZosRenderStyle({
    required this.theme,
    required this.circles,
    required this.dropped,
  });

  /// Input for `ThemeReader.read`.
  final Map<String, dynamic> theme;

  /// The sprites the converted `circle` layers name.
  final List<ZosCircleSprite> circles;

  /// Ids of the layers left out (the POV hatch, or anything not convertible).
  final List<String> dropped;
}

/// Converts the style narcis-vibed serves (NV-546) for the phone's renderer,
/// keeping only the layers of [sourceLayers] (the active sublayer slugs).
///
/// The style is the web map's own, untailored. The renderer cannot draw three
/// things in it, so (TB-47):
/// - a `circle` layer becomes a `symbol` layer of dot sprites ([circles]),
///   one per colour its `circle-color` can take (a literal or a `match`);
/// - a `fill-pattern` layer (the Natura 2000 POV hatch) is dropped — POV keeps
///   its outline from the line layer;
/// - a `symbol` layer without `paint` gets one, because the renderer skips a
///   symbol layer that has none (re-checked 2026-11-04: it draws 0 px).
///
/// [kZosMonumentSlug] in [sourceLayers] draws ZO's natural monuments; `zo`
/// without it draws ZO without them (TB-37). The split is an added filter on
/// the ZO layers, in the expression form the renderer reads.
///
/// The theme id names the active set, because the map's raster cache is keyed
/// on it: tiles drawn for one set must not be served for another.
ZosRenderStyle zosRenderStyle(
  Map<String, dynamic> style,
  Set<String> sourceLayers,
) {
  final zo = sourceLayers.contains('zo');
  final ns = sourceLayers.contains(kZosMonumentSlug);
  final drawn = {...sourceLayers, if (ns) 'zo'};
  // Null when both halves of ZO are on (or neither): no split to draw.
  final List<Object>? zoSplit = zo == ns
      ? null
      : [zo ? '!=' : '==', ['get', '_cls'], kZoMonumentClass];
  final layers = <Map<String, dynamic>>[];
  final circles = <ZosCircleSprite>[];
  final dropped = <String>[];
  for (final raw in (style['layers'] as List? ?? const [])) {
    if (raw is! Map) continue;
    // Deep copy: the served style stays as it came.
    final l = (jsonDecode(jsonEncode(raw)) as Map).cast<String, dynamic>();
    if (!drawn.contains(l['source-layer'])) continue;
    if (zoSplit != null && l['source-layer'] == 'zo') {
      final f = l['filter'];
      l['filter'] = f == null ? zoSplit : ['all', f, zoSplit];
    }
    final id = '${l['id']}';
    final paint = l['paint'];
    switch (l['type']) {
      case 'circle':
        final symbol = _circleToSymbol(l, circles);
        if (symbol == null) {
          dropped.add(id);
        } else {
          layers.add(symbol);
        }
      case 'fill' when paint is Map && paint.containsKey('fill-pattern'):
        dropped.add(id);
      case 'symbol' when paint == null:
        layers.add({...l, 'paint': _symbolPaint});
      default:
        layers.add(l);
    }
  }
  final slugs = sourceLayers.toList()..sort();
  final version = '${(style['metadata'] as Map?)?['version'] ?? 'none'}';
  return ZosRenderStyle(
    theme: {
      'version': 8,
      'id': '${style['id'] ?? 'zos'}_${slugs.join('.')}',
      'metadata': {'version': '$version-r$kZosRendererRevision'},
      'sources': style['sources'] ?? const {},
      'layers': layers,
    },
    circles: circles,
    dropped: dropped,
  );
}

/// MapLibre's default text colour; only there to satisfy the renderer.
const Map<String, dynamic> _symbolPaint = {'text-color': '#000000'};

Map<String, dynamic>? _circleToSymbol(
  Map<String, dynamic> l,
  List<ZosCircleSprite> out,
) {
  final paint = (l['paint'] as Map?)?.cast<String, dynamic>() ?? const {};
  // MapLibre's defaults for the four keys narcis-vibed's guard allows.
  final radius = paint['circle-radius'] ?? 5;
  final strokeWidth = paint['circle-stroke-width'] ?? 0;
  final strokeColor = parseZosColor(paint['circle-stroke-color'] ?? '#000000');
  final color = paint['circle-color'] ?? '#000000';
  if (radius is! num || strokeWidth is! num || strokeColor == null) return null;

  final id = '${l['id']}';
  final sprites = <ZosCircleSprite>[];
  String sprite(Object? c) {
    final argb = parseZosColor(c);
    if (argb == null) throw const FormatException('colour');
    final name = 'circle-$id-${sprites.length}';
    sprites.add(ZosCircleSprite(
      name: name,
      radius: radius.toDouble(),
      color: argb,
      strokeColor: strokeColor,
      strokeWidth: strokeWidth.toDouble(),
    ));
    return name;
  }

  final Object icon;
  try {
    if (color is String) {
      icon = sprite(color);
    } else if (color is List &&
        color.length >= 5 &&
        color.length.isOdd &&
        color.first == 'match') {
      // ['match', input, label1, out1, ..., labelN, outN, fallback]: swap
      // each output colour for its sprite's name; labels stay as they are.
      final m = [...color];
      for (var i = 3; i < m.length - 1; i += 2) {
        m[i] = sprite(m[i]);
      }
      m[m.length - 1] = sprite(m.last);
      icon = m;
    } else {
      return null;
    }
  } on FormatException {
    return null;
  }
  out.addAll(sprites);
  return {
    'id': l['id'],
    'type': 'symbol',
    'source': l['source'],
    'source-layer': l['source-layer'],
    if (l['filter'] != null) 'filter': l['filter'],
    if (l['minzoom'] != null) 'minzoom': l['minzoom'],
    if (l['maxzoom'] != null) 'maxzoom': l['maxzoom'],
    'layout': {'icon-image': icon},
    'paint': _symbolPaint,
  };
}

/// `#rgb`, `#rrggbb`, `rgb(r,g,b)` or `rgba(r,g,b,a)` → ARGB; null otherwise.
int? parseZosColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  if (s.startsWith('#')) {
    var hex = s.substring(1);
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length != 6) return null;
    final rgb = int.tryParse(hex, radix: 16);
    return rgb == null ? null : 0xFF000000 | rgb;
  }
  final m = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(s);
  if (m == null) return null;
  final parts = m.group(1)!.split(',').map((p) => p.trim()).toList();
  if (parts.length != 3 && parts.length != 4) return null;
  final rgb = parts.take(3).map(int.tryParse).toList();
  if (rgb.any((c) => c == null || c < 0 || c > 255)) return null;
  final a = parts.length == 4 ? double.tryParse(parts[3]) : 1.0;
  if (a == null || a < 0 || a > 1) return null;
  return ((a * 255).round() << 24) | (rgb[0]! << 16) | (rgb[1]! << 8) | rgb[2]!;
}
