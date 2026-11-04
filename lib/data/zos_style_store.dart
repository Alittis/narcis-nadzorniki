import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Where the protected-area ("Območja s statusom") map data comes from:
/// narcis-vibed on the VPS serves the tileset (NV-400), its style and its icon
/// sprite (NV-546) — the same ones the web map draws. Public data, so every
/// build reads production, whatever `BELEZNICA_API` points at.
const String kZosOrigin = 'https://narcis.alittis.com';

/// The basemap tone a served style is drawn for: OSM is light, the satellite
/// imagery dark (as on the web, where Satelit is dark-toned).
enum ZosTone { light, dark }

/// One row of the served legend (`metadata["narcis:legend"]`). [key] is the
/// `_cls` the tile features carry, null on a single-class layer (epo, nvj).
class ZosLegendRow {
  const ZosLegendRow({
    required this.key,
    required this.label,
    required this.color,
  });

  final String? key;
  final String label;
  final String color; // '#rrggbb'
}

/// A served style with the sprite it names, as the device keeps it.
class ZosStyleBundle {
  ZosStyleBundle({
    required this.tone,
    required this.etag,
    required this.style,
    required this.spriteIndex,
    required this.spritePng,
  });

  final ZosTone tone;
  final String? etag;
  final Map<String, dynamic> style;
  final Map<String, dynamic> spriteIndex;
  final Uint8List spritePng;

  /// Changes whenever the style, the sprite or the tileset's content changes.
  String get version => '${(style['metadata'] as Map?)?['version'] ?? ''}';

  String get id => '${style['id'] ?? 'zos'}';

  /// The PMTiles archive the style's `zos` source names, without `pmtiles://`.
  String get tilesUrl {
    final url = '${(style['sources'] as Map)['zos']['url']}';
    return url.startsWith('pmtiles://') ? url.substring(10) : url;
  }

  /// Legend rows per source layer (slug), in the served order.
  Map<String, List<ZosLegendRow>> get legend {
    final raw = (style['metadata'] as Map?)?['narcis:legend'];
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.value is List)
          '${e.key}': [
            for (final r in e.value as List)
              if (r is Map && r['color'] is String)
                ZosLegendRow(
                  key: r['key'] as String?,
                  label: '${r['label'] ?? ''}',
                  color: r['color'] as String,
                ),
          ],
    };
  }
}

/// Fetches the served style and sprite, revalidates them by ETag, and keeps
/// the last good pair per tone on the device, so the layer still draws offline
/// (from tiles already cached) and opens without waiting for the network.
class ZosStyleStore {
  ZosStyleStore({
    http.Client? client,
    Future<Directory> Function()? directory,
    this.origin = kZosOrigin,
  })  : _client = client ?? http.Client(),
        _directory = directory ?? getApplicationDocumentsDirectory;

  final http.Client _client;
  final Future<Directory> Function() _directory;
  final String origin;

  static const _timeout = Duration(seconds: 20);

  Future<Directory> _dir() async {
    final d = Directory('${(await _directory()).path}/zos_style');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// The bundle last saved for [tone], or null when there is none (or it is
  /// damaged).
  Future<ZosStyleBundle?> cached(ZosTone tone) async {
    try {
      final d = await _dir();
      final style = File('${d.path}/style-${tone.name}.json');
      final index = File('${d.path}/sprite-${tone.name}.json');
      final png = File('${d.path}/sprite-${tone.name}.png');
      if (!await style.exists() ||
          !await index.exists() ||
          !await png.exists()) {
        return null;
      }
      final meta = jsonDecode(await style.readAsString()) as Map;
      return _validated(ZosStyleBundle(
        tone: tone,
        etag: meta['etag'] as String?,
        style: (meta['style'] as Map).cast<String, dynamic>(),
        spriteIndex: (jsonDecode(await index.readAsString()) as Map)
            .cast<String, dynamic>(),
        spritePng: await png.readAsBytes(),
      ));
    } catch (_) {
      return null;
    }
  }

  /// Asks the VPS for [tone]'s style, revalidating [current] by its ETag.
  /// Returns [current] when unchanged (304), otherwise the new bundle with its
  /// sprite, already saved. Throws [ZosStyleException] when the VPS cannot be
  /// reached or answers with something unusable.
  Future<ZosStyleBundle> refresh(ZosTone tone,
      {ZosStyleBundle? current}) async {
    final res = await _get(
      Uri.parse('$origin/api/layers/zos-style?tone=${tone.name}'),
      etag: current?.etag,
    );
    if (res.statusCode == 304 && current != null) return current;
    if (res.statusCode != 200) {
      throw ZosStyleException('style: HTTP ${res.statusCode}');
    }
    final Map<String, dynamic> style;
    try {
      style = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      throw ZosStyleException('style: not JSON ($e)');
    }
    final sprite = style['sprite'];
    if (sprite is! String) throw ZosStyleException('style: no sprite');
    // The style's version covers the sprite, so a changed style is the only
    // time the sprite needs fetching.
    final index = await _get(Uri.parse('$sprite@2x.json'));
    final png = await _get(Uri.parse('$sprite@2x.png'));
    if (index.statusCode != 200 || png.statusCode != 200) {
      throw ZosStyleException(
          'sprite: HTTP ${index.statusCode} / ${png.statusCode}');
    }
    final Map<String, dynamic> spriteIndex;
    try {
      spriteIndex = (jsonDecode(utf8.decode(index.bodyBytes)) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      throw ZosStyleException('sprite index: not JSON ($e)');
    }
    final bundle = _validated(ZosStyleBundle(
      tone: tone,
      etag: res.headers['etag'],
      style: style,
      spriteIndex: spriteIndex,
      spritePng: png.bodyBytes,
    ));
    if (bundle == null) throw ZosStyleException('style: missing fields');
    await _save(bundle);
    return bundle;
  }

  Future<http.Response> _get(Uri uri, {String? etag}) async {
    try {
      return await _client.get(uri, headers: {
        'if-none-match': ?etag,
      }).timeout(_timeout);
    } catch (e) {
      throw ZosStyleException('$uri: $e');
    }
  }

  /// Best-effort; a failed save only means the next start fetches again.
  Future<void> _save(ZosStyleBundle b) async {
    try {
      final d = await _dir();
      final t = b.tone.name;
      await _write(File('${d.path}/sprite-$t.png'), b.spritePng);
      await _write(File('${d.path}/sprite-$t.json'),
          utf8.encode(jsonEncode(b.spriteIndex)));
      // The style last: it is what [cached] checks first.
      await _write(File('${d.path}/style-$t.json'),
          utf8.encode(jsonEncode({'etag': b.etag, 'style': b.style})));
    } catch (_) {}
  }

  /// Write-then-rename, so a crash never leaves half a file.
  static Future<void> _write(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  /// Null unless the bundle has what the map needs.
  static ZosStyleBundle? _validated(ZosStyleBundle b) {
    try {
      if (b.style['layers'] is! List) return null;
      if (b.version.isEmpty) return null;
      if (b.tilesUrl.isEmpty) return null;
      return b;
    } catch (_) {
      return null;
    }
  }
}

class ZosStyleException implements Exception {
  ZosStyleException(this.message);

  final String message;

  @override
  String toString() => 'ZosStyleException: $message';
}
