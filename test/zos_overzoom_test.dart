// TB-47: tiles past the archive's z15 are built from their z15 ancestor by
// scaling and shifting coordinates only — no cut along the tile edge, which
// vector_map_tiles' own over-zoom makes and every outline layer then draws.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/zos_overzoom.dart';
import 'package:vector_tile/vector_tile.dart' as vt;

final _z15 = Uint8List.fromList(
    File('test/fixtures/zos/z15-17691-11690.mvt').readAsBytesSync());

/// Every position of every feature, layer by layer, in feature order.
List<List<double>> _positions(Uint8List bytes) {
  final out = <List<double>>[];
  void ring(List<List<double>> r) => out.addAll(r);
  for (final layer in vt.VectorTile.fromBytes(bytes: bytes).layers) {
    for (final f in layer.features) {
      switch (f.decodeGeometry()) {
        case vt.GeometryPoint(:final coordinates):
          out.add(coordinates);
        case vt.GeometryMultiPoint(:final coordinates):
          out.addAll(coordinates);
        case vt.GeometryLineString(:final coordinates):
          ring(coordinates);
        case vt.GeometryMultiLineString(:final coordinates):
          coordinates.forEach(ring);
        case vt.GeometryPolygon(:final coordinates):
          coordinates.forEach(ring);
        case vt.GeometryMultiPolygon(:final coordinates):
          for (final p in coordinates ?? const <List<List<List<double>>>>[]) {
            p.forEach(ring);
          }
        default:
      }
    }
  }
  return out;
}

void main() {
  final parent = _positions(_z15);

  test('a z17 tile is its ancestor scaled by 4 and shifted to its cell', () {
    // z17 tile (x, y) = ancestor (17691, 11690) * 4 + (3, 1).
    final child = _positions(zosOverzoomTile(_z15,
        maxZ: 15, z: 17, x: 17691 * 4 + 3, y: 11690 * 4 + 1));
    expect(child.length, parent.length);
    for (var i = 0; i < parent.length; i++) {
      expect(child[i], [parent[i][0] * 4 - 3 * 4096, parent[i][1] * 4 - 4096]);
    }
  });

  test('nothing is dropped and the properties stay', () {
    final child = vt.VectorTile.fromBytes(
        bytes: zosOverzoomTile(_z15, maxZ: 15, z: 16, x: 35382, y: 23380));
    final source = vt.VectorTile.fromBytes(bytes: _z15);
    expect(child.layers.map((l) => l.name), source.layers.map((l) => l.name));
    for (var i = 0; i < source.layers.length; i++) {
      final a = source.layers[i].features, b = child.layers[i].features;
      expect(b.map((f) => f.id), a.map((f) => f.id));
      expect(b.map((f) => f.decodeProperties()['IME_OBM']?.dartStringValue),
          a.map((f) => f.decodeProperties()['IME_OBM']?.dartStringValue));
    }
  });

  test('at or above the archive zoom the tile is passed through', () {
    expect(
        identical(
            zosOverzoomTile(_z15, maxZ: 15, z: 15, x: 17691, y: 11690), _z15),
        isTrue);
  });
}
