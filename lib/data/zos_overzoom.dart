import 'dart:typed_data';

import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

/// The vector tile at [z]/[x]/[y], deeper than the archive's deepest zoom
/// [maxZ], built from its z[maxZ] ancestor [parent] by scaling and shifting
/// every coordinate. Nothing is cut: geometry reaching past the tile stays,
/// and the renderer's canvas trims it to the tile.
///
/// Why (TB-47): vector_map_tiles 9.0.0-beta.9 (unchanged in beta.13) over-zooms
/// in raster mode by clipping the ancestor exactly at the child tile's edge,
/// with no buffer (`vector_tile_loading_cache.dart` `_createTile`). Every
/// outline layer then draws that cut as a line, a faint grid at z16 and up
/// (seen on the A56, 2026-11-04). Serving the deeper tiles from here keeps the
/// library from over-zooming at all.
Uint8List zosOverzoomTile(
  Uint8List parent, {
  required int maxZ,
  required int z,
  required int x,
  required int y,
}) {
  final dz = z - maxZ;
  if (dz <= 0) return parent;
  final scale = 1 << dz;
  // The child's column and row inside its ancestor.
  final cx = x - ((x >> dz) << dz);
  final cy = y - ((y >> dz) << dz);
  final tile = raw.VectorTile.fromBuffer(parent);
  for (final layer in tile.layers) {
    final extent = layer.extent;
    for (final f in layer.features) {
      final moved =
          _transform(f.geometry, scale, cx * extent, cy * extent);
      f.geometry
        ..clear()
        ..addAll(moved);
    }
  }
  return tile.writeToBuffer();
}

/// Re-encodes MVT geometry commands with each position p mapped to
/// p * [scale] - offset. Command integers stay as they are.
List<int> _transform(List<int> g, int scale, int offX, int offY) {
  final out = <int>[];
  var i = 0;
  var px = 0, py = 0; // cursor in the ancestor's units
  var qx = 0, qy = 0; // cursor in the child's units
  while (i < g.length) {
    final command = g[i++];
    out.add(command);
    final id = command & 0x7, count = command >> 3;
    if (id != 1 && id != 2) continue; // ClosePath carries no parameters
    for (var k = 0; k < count && i + 1 < g.length; k++) {
      px += _unzigzag(g[i++]);
      py += _unzigzag(g[i++]);
      final nx = px * scale - offX, ny = py * scale - offY;
      out
        ..add(_zigzag(nx - qx))
        ..add(_zigzag(ny - qy));
      qx = nx;
      qy = ny;
    }
  }
  return out;
}

int _unzigzag(int n) => (n >> 1) ^ -(n & 1);

int _zigzag(int n) => (n << 1) ^ (n >> 31);
