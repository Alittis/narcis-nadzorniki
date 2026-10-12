// TB-40: the home map remembers its layer setup across restarts.
//
// What matters is that a remembered choice comes back exactly (including
// "everything off"), that a damaged or foreign file can never break the map,
// and that the Motnje filter is NOT part of what is remembered.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/map_layers_store.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

void main() {
  late Directory dir;
  late MapLayersStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('map_layers_test');
    store = MapLayersStore(directory: () async => dir);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> writeRaw(String content) =>
      File('${dir.path}/map_layers.json').writeAsString(content);

  test('a first start has nothing to restore', () async {
    expect(await store.load(), isNull);
  });

  test('what was saved comes back — Natura 2000 off included', () async {
    // Matjaž's example: he turns N2k off and wants it to stay off.
    await store.save(const MapLayers(
      basemap: BasemapMode.satellite,
      showMotnje: false,
      showObhodi: true,
      showParcele: true,
      zos: {ZosKind.zo, ZosKind.nv},
    ));

    final restored = await store.load();

    expect(restored!.basemap, BasemapMode.satellite);
    expect(restored.showMotnje, isFalse);
    expect(restored.showObhodi, isTrue);
    expect(restored.showParcele, isTrue);
    expect(restored.zos, {ZosKind.zo, ZosKind.nv});
  });

  test('all Območja off is remembered as off, not reset to the default',
      () async {
    await store.save(const MapLayers(
      basemap: BasemapMode.osm,
      showMotnje: true,
      showObhodi: false,
      showParcele: false,
      zos: {},
    ));
    expect((await store.load())!.zos, isEmpty);
  });

  test('only layers are stored — never the Motnje filter', () {
    expect(MapLayers.defaults.toJson().keys,
        unorderedEquals(['basemap', 'motnje', 'obhodi', 'parcele', 'obmocja']));
  });

  test('a damaged file is ignored, so the map opens with the defaults',
      () async {
    await writeRaw('{not json');
    expect(await store.load(), isNull);
  });

  test('unknown or missing values fall back one by one', () async {
    // As a file from an older or newer build might look.
    await writeRaw('{"basemap":"terrain","obhodi":true,'
        '"obmocja":["n2k","unknown","nvj"]}');

    final restored = (await store.load())!;

    expect(restored.basemap, MapLayers.defaults.basemap);
    expect(restored.showMotnje, MapLayers.defaults.showMotnje);
    expect(restored.showObhodi, isTrue);
    expect(restored.showParcele, MapLayers.defaults.showParcele);
    expect(restored.zos, {ZosKind.n2k, ZosKind.nvj});
  });
}
