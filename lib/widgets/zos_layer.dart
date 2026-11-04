import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/data/zos_overzoom.dart';
import 'package:narcis_nadzorniki/data/zos_render_style.dart';
import 'package:narcis_nadzorniki/data/zos_style_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pmtiles/pmtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// The "Območja s statusom" overlay (TB-47): the VPS tileset drawn on the
/// device with the web map's own style. Owns what the layer needs — the style
/// bundle for the basemap's tone, the open PMTiles archive, the sprite atlas
/// and a tile cache folder — and swaps them together when the style's version
/// changes (a new style, sprite or tileset).
///
/// Why the cache folder is per version: `vector_map_tiles` keys its cached
/// raster tiles on the theme id and version, but its cached tile DATA only on
/// z/x/y. A new tileset under the same folder would draw old data.
class ZosOverlay extends ChangeNotifier {
  ZosOverlay({
    ZosStyleStore? store,
    Future<PmTilesArchive> Function(String url)? openArchive,
    Future<Directory> Function()? cacheRoot,
  })  : _store = store ?? ZosStyleStore(),
        _open = openArchive ?? PmTilesArchive.from,
        _cacheRoot = cacheRoot ?? getTemporaryDirectory;

  final ZosStyleStore _store;
  final Future<PmTilesArchive> Function(String url) _open;
  final Future<Directory> Function() _cacheRoot;

  ZosTone? _tone;
  _Loaded? _loaded;
  final _themes = <String, vtr.Theme>{};
  Future<void>? _checking;
  DateTime? _lastErrorCheck;
  bool _disposed = false;

  /// The bundle on screen, for the legend; null until one has loaded.
  ZosStyleBundle? get bundle => _loaded?.bundle;

  /// Shows [tone]'s style: the copy on the device at once, then whatever the
  /// VPS says about it.
  Future<void> useTone(ZosTone tone) async {
    if (_tone == tone) return;
    _tone = tone;
    final cached = await _store.cached(tone);
    if (_tone != tone) return;
    if (cached != null) await _apply(cached);
    await recheck();
  }

  /// Revalidates the style with the VPS: on app resume, and after a tile read
  /// fails (an archive held open across a publish reads the new file at old
  /// offsets until the new version is applied). One check at a time.
  Future<void> recheck() =>
      _checking ??= _recheck().whenComplete(() => _checking = null);

  Future<void> _recheck() async {
    final tone = _tone;
    if (tone == null) return;
    final on = _loaded?.bundle;
    try {
      final current = on?.tone == tone ? on : await _store.cached(tone);
      final fresh = await _store.refresh(tone, current: current);
      if (_tone == tone && fresh.version != _loaded?.bundle.version) {
        await _apply(fresh);
      }
    } on ZosStyleException catch (e) {
      debugPrint('[zos] style check failed: $e');
    }
  }

  void _onTileError() {
    final now = DateTime.now();
    final last = _lastErrorCheck;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastErrorCheck = now;
    unawaited(recheck());
  }

  Future<void> _apply(ZosStyleBundle b) async {
    final previous = _loaded;
    if (previous != null && previous.bundle.version == b.version) return;
    PmTilesArchive? archive;
    try {
      archive = await _open(b.tilesUrl);
      final sprites = await zosSpriteStyle(b);
      final dir = await _cacheDir(b.version);
      if (_disposed || _tone != b.tone) {
        await archive.close();
        return;
      }
      _loaded = _Loaded(
        bundle: b,
        archive: archive,
        provider: _WatchedProvider(
          _OverzoomProvider(PmTilesVectorTileProvider.fromArchive(archive)),
          _onTileError,
        ),
        sprites: sprites,
        cacheDir: dir,
      );
      _themes.clear();
      notifyListeners();
      debugPrint('[zos] ${b.tone.name} style ${b.version} on');
      if (previous != null) {
        // Let tile reads already in flight finish on the old archive.
        Future.delayed(const Duration(seconds: 30), previous.archive.close);
      }
      unawaited(_sweep(b));
    } catch (e) {
      debugPrint('[zos] could not load style ${b.version}: $e');
      if (!identical(_loaded?.archive, archive)) unawaited(archive?.close());
    }
  }

  Future<Directory> _cacheDir(String version) async {
    final d = Directory('${(await _cacheRoot()).path}/zos_tiles/$version');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Deletes tile caches of versions no tone uses any more.
  Future<void> _sweep(ZosStyleBundle on) async {
    try {
      final keep = {on.version};
      for (final t in ZosTone.values) {
        if (t != on.tone) {
          final v = (await _store.cached(t))?.version;
          if (v != null) keep.add(v);
        }
      }
      final root = Directory('${(await _cacheRoot()).path}/zos_tiles');
      await for (final e in root.list()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory && !keep.contains(name)) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  /// Reads one z/x/y tile of the open archive, for identify; null when the
  /// archive has no tile there. Throws when nothing has loaded yet.
  Future<Uint8List?> readTile(int z, int x, int y) async {
    final archive = _loaded?.archive;
    if (archive == null) throw StateError('Območja: no tileset loaded');
    final tile = await archive.tile(ZXY(z, x, y).toTileId());
    try {
      return Uint8List.fromList(tile.bytes());
    } on TileNotFoundException {
      return null;
    }
  }

  /// The map layer for the [active] sublayers; null while nothing has loaded.
  Widget? layer(Set<ZosKind> active) {
    final l = _loaded;
    if (l == null || active.isEmpty) return null;
    final slugs = {for (final k in active) k.name};
    final key = (slugs.toList()..sort()).join('.');
    final theme = _themes[key] ??= vtr.ThemeReader(logger: const _ZosLog())
        .read(zosRenderStyle(l.bundle.style, slugs).theme);
    return vmt.VectorTileLayer(
      key: ValueKey('${theme.id}@${theme.version}'),
      theme: theme,
      sprites: l.sprites,
      tileProviders: vmt.TileProviders({'zos': l.provider}),
      // Raster mode: smooth on the A56 with every layer on; vector mode is
      // not (TB-47 spike, part 2).
      layerMode: vmt.VectorTileLayerMode.raster,
      // The parameter's `Directory` is a conditional typedef (dart:io's on
      // devices, String on the web stub the analyzer resolves), hence dynamic.
      cacheFolder: () async => l.cacheDir as dynamic,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_loaded?.archive.close());
    super.dispose();
  }
}

class _Loaded {
  _Loaded({
    required this.bundle,
    required this.archive,
    required this.provider,
    required this.sprites,
    required this.cacheDir,
  });

  final ZosStyleBundle bundle;
  final PmTilesArchive archive;
  final vmt.VectorTileProvider provider;
  final vmt.SpriteStyle sprites;
  final Directory cacheDir;
}

/// Serves the zooms past the archive's deepest (z15) up to the raster layer's
/// native maximum, built from their z15 ancestor by [zosOverzoomTile], so the
/// library never over-zooms (and never cuts outlines at the tile edge).
class _OverzoomProvider extends vmt.VectorTileProvider {
  _OverzoomProvider(this._inner);

  final vmt.VectorTileProvider _inner;

  /// The raster layer's default native maximum (`VectorTileLayer.maximumZoom`
  /// unset = 18); the map scales its z18 tiles up to its own z19.
  static const _maxZoom = 18;

  /// Recent ancestors: one z15 tile feeds up to 4 + 16 + 64 deeper tiles.
  final _ancestors = <String, Future<Uint8List>>{};

  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) async {
    final top = _inner.maximumZoom;
    if (tile.z <= top) return _inner.provide(tile);
    final dz = tile.z - top;
    final parent = vmt.TileIdentity(top, tile.x >> dz, tile.y >> dz);
    final key = '${parent.x}/${parent.y}';
    final future = _ancestors.remove(key) ?? _inner.provide(parent);
    _ancestors[key] = future; // most recent last
    if (_ancestors.length > 16) _ancestors.remove(_ancestors.keys.first);
    try {
      return zosOverzoomTile(await future,
          maxZ: top, z: tile.z, x: tile.x, y: tile.y);
    } catch (_) {
      _ancestors.remove(key); // do not keep a failed read
      rethrow;
    }
  }

  @override
  int get maximumZoom => _maxZoom;

  @override
  int get minimumZoom => _inner.minimumZoom;

  @override
  vmt.TileOffset get tileOffset => _inner.tileOffset;
}

/// Passes tiles through; reports a failed read other than "no tile here".
class _WatchedProvider extends vmt.VectorTileProvider {
  _WatchedProvider(this._inner, this._onError);

  final vmt.VectorTileProvider _inner;
  final void Function() _onError;

  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) async {
    try {
      return await _inner.provide(tile);
    } on vmt.ProviderException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 204) _onError();
      rethrow;
    } catch (_) {
      _onError();
      rethrow;
    }
  }

  @override
  int get maximumZoom => _inner.maximumZoom;

  @override
  int get minimumZoom => _inner.minimumZoom;

  @override
  vmt.TileOffset get tileOffset => _inner.tileOffset;
}

/// The renderer's warnings mean part of the style did not take; say so.
class _ZosLog implements vtr.Logger {
  const _ZosLog();

  @override
  void log(String Function() message) {}

  @override
  void warn(String Function() message) =>
      debugPrint('[zos] renderer: ${message()}');
}

/// The served sprite (pixel ratio 2) with the converted circle layers' dots
/// drawn in a row below it, as one atlas and index.
Future<vmt.SpriteStyle> zosSpriteStyle(ZosStyleBundle b) async {
  final circles = zosRenderStyle(
    b.style,
    {for (final k in ZosKind.values) k.name},
  ).circles;
  final server = await decodeImageFromList(b.spritePng);
  const ratio = 2.0;
  final index = <String, dynamic>{...b.spriteIndex};
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec)..drawImage(server, Offset.zero, ui.Paint());
  final top = server.height + 2;
  var x = 0, rowHeight = 0;
  for (final s in circles) {
    final px = (s.size * ratio).ceil();
    final centre = Offset(s.size / 2, s.size / 2);
    canvas
      ..save()
      ..translate(x.toDouble(), top.toDouble())
      ..scale(ratio)
      ..drawCircle(centre, s.radius, ui.Paint()..color = ui.Color(s.color));
    if (s.strokeWidth > 0) {
      // MapLibre draws the stroke outside the radius.
      canvas.drawCircle(
        centre,
        s.radius + s.strokeWidth / 2,
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = s.strokeWidth
          ..color = ui.Color(s.strokeColor),
      );
    }
    canvas.restore();
    index[s.name] = {
      'x': x,
      'y': top,
      'width': px,
      'height': px,
      'pixelRatio': ratio.toInt(),
    };
    x += px + 2;
    rowHeight = math.max(rowHeight, px);
  }
  final atlas = await rec
      .endRecording()
      .toImage(math.max(server.width, x), top + rowHeight);
  final png = (await atlas.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  server.dispose();
  atlas.dispose();
  return vmt.SpriteStyle(
    atlasProvider: () async => png,
    index: vtr.SpriteIndexReader().read(index),
  );
}
