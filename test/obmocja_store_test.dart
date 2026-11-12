// TB-47: tap-to-identify reads the VPS tileset itself — the z15 tile under the
// tap, plus a neighbour near its edge — then each hit's detail from the VPS
// register. The tiles are real ones saved from narcis-vibed's zos.pmtiles
// (test/fixtures/zos), so the geometry and properties are the live schema;
// the network is a MockClient. z15-17797-11596 (Frajhajm, near Fram) was saved
// on 2026-11-12, archive version 106b1f98a980, for its ZO natural monuments
// (TB-37); the others on 2026-11-04.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/data/zos_style_store.dart';

Uint8List _tile(int x, int y) =>
    File('test/fixtures/zos/z15-$x-$y.mvt').readAsBytesSync();

/// Reads the fixture tiles; null (no tile) anywhere else.
Future<Uint8List?> _readFixture(int z, int x, int y) async {
  final f = File('test/fixtures/zos/z15-$x-$y.mvt');
  return z == 15 && f.existsSync() ? f.readAsBytesSync() : null;
}

final _legend = ZosStyleBundle(
  tone: ZosTone.light,
  etag: null,
  style: (jsonDecode(File('test/fixtures/zos/style-light.json')
          .readAsStringSync()) as Map)
      .cast<String, dynamic>(),
  spriteIndex: const {},
  spritePng: Uint8List(0),
).legend;

// Cerknica lake: inside nine areas of five layers. 0.989 across its tile, so
// the neighbour to the east is read too.
const _cerknica = LatLng(45.75, 14.37);
// A cave of the Kras fixture tile (#9393, Sežansko brezno).
const _cave = LatLng(45.706235, 13.854323);
const _metresPerDegreeLat = 111320.0;
// Korošičeve lipe v Frajhajmu (#101639), a ZO natural monument (a point).
const _lipe = LatLng(46.4681, 15.5319);

void main() {
  group('zosTilesAround', () {
    test('a tap near the east edge also reads the eastern neighbour', () {
      expect(zosTilesAround(_cerknica, 50), [(17691, 11690), (17692, 11690)]);
    });

    test('a tap mid-tile reads one tile', () {
      // The middle of tile 17691/11690.
      expect(zosTilesAround(const LatLng(45.74836, 14.36462), 50),
          [(17691, 11690)]);
    });
  });

  group('zosHitTest', () {
    test('areas contain the tap, in every active layer', () {
      final hits = zosHitTest(_tile(17691, 11690), 17691, 11690, _cerknica,
          ZosKind.values.toSet(), 50);
      expect(hits.map((h) => h.id).toSet(), {
        401, 577, // epo
        102997, // mvo: Cerkniško jezero (Ramsar)
        1263, 1275, // n2k: POO Notranjski trikotnik, POV Cerkniško jezero
        2491, 5427, 20957, // nv
        102835, // zo: Notranjski regijski park
      });
      expect(hits.every((h) => !h.isPoint), isTrue);
      final pov = hits.singleWhere((h) => h.id == 1275);
      expect(pov.kind, ZosKind.n2k);
      expect(pov.props['_cls'], 'POV');
      expect(pov.props['IME_OBM'], 'Cerkniško jezero');
    });

    test('only the active layers are read', () {
      final hits = zosHitTest(_tile(17691, 11690), 17691, 11690, _cerknica,
          {ZosKind.zo}, 50);
      expect(hits.map((h) => h.id), [102835]);
    });

    test('TB-37: a natural monument hits as ns, and only when ns is on', () {
      List<(int, ZosKind)> hits(Set<ZosKind> active) =>
          zosHitTest(_tile(17797, 11596), 17797, 11596, _lipe, active, 50)
              .where((h) => h.id == 101639)
              .map((h) => (h.id, h.kind))
              .toList();

      expect(hits({ZosKind.ns}), [(101639, ZosKind.ns)]);
      expect(hits({ZosKind.zo, ZosKind.ns}), [(101639, ZosKind.ns)]);
      expect(hits({ZosKind.zo}), isEmpty, reason: 'ZO alone leaves them out');
    });

    test('TB-37: the rest of ZO hits as zo, never as ns', () {
      List<int> ids(Set<ZosKind> active) => zosHitTest(_tile(17691, 11690),
              17691, 11690, _cerknica, active, 50)
          .map((h) => h.id)
          .toList();

      expect(ids({ZosKind.ns}), isEmpty);
      expect(ids({ZosKind.zo, ZosKind.ns}), [102835]);
    });

    test('a point counts within the radius, not beyond it', () {
      LatLng north(double m) =>
          LatLng(_cave.latitude + m / _metresPerDegreeLat, _cave.longitude);
      List<int> hitIds(LatLng tap) => zosHitTest(_tile(17645, 11696), 17645,
              11696, tap, {ZosKind.nvj}, 50)
          .map((h) => h.id)
          .toList();

      expect(hitIds(north(30)), [9393]);
      expect(hitIds(north(80)), isEmpty);
      final hit = zosHitTest(_tile(17645, 11696), 17645, 11696, north(30),
              {ZosKind.nvj}, 50)
          .single;
      expect(hit.isPoint, isTrue);
      expect(hit.props['IME_OBM'], 'Sežansko brezno');
    });
  });

  group('ObmocjaStore.identify', () {
    test('one entry per area across both tiles, with its VPS detail', () async {
      final asked = <String>[];
      final store = ObmocjaStore(
        client: MockClient((req) async {
          asked.add(req.url.path);
          if (req.url.path == '/api/layers/detail/1275') {
            return http.Response.bytes(
                utf8.encode(jsonEncode({
                  'id': 1275,
                  'opis': 'Presihajoče jezero …',
                  'n2k_tip_obmocja': 'POV (SPA)',
                  'n2k_biogeo_region': 'celinska',
                  'povrsina_ha': 2620.5,
                  'dat_ustan': '2004-04-30',
                })),
                200);
          }
          return http.Response('{"error":"not found"}', 404);
        }),
      );

      final feats = await store.identify(_cerknica, ZosKind.values.toSet(),
          readTile: _readFixture, legend: _legend);

      // Nine areas, though both tiles hold all nine: deduplicated by id.
      expect(feats.map((f) => f.id).toSet().length, 9);
      expect(feats.length, 9);
      // Grouped in picker order: n2k, zo, epo, nv, nvj, mvo.
      expect(feats.map((f) => f.kind).toList(), [
        ZosKind.n2k, ZosKind.n2k, ZosKind.zo, ZosKind.epo, ZosKind.epo, //
        ZosKind.nv, ZosKind.nv, ZosKind.nv, ZosKind.mvo,
      ]);
      expect(asked.where((p) => p.startsWith('/api/layers/detail/')).length, 9);

      bool hasRow(ObmocjeFeature f, String label, String value) =>
          f.rows.any((e) => e.key == label && e.value == value);

      final pov = feats.singleWhere((f) => f.id == 1275);
      expect(pov.ime, 'Cerkniško jezero');
      expect(pov.koda, 'SI5000015');
      expect(pov.cls, 'POV');
      expect(pov.opis, 'Presihajoče jezero …');
      expect(hasRow(pov, 'Tip', 'POV (SPA)'), isTrue); // detail wins
      expect(hasRow(pov, 'Površina', '2620.5 ha'), isTrue);
      expect(hasRow(pov, 'Datum začetka', '2004-04-30'), isTrue);
      expect(pov.color, 0xFF7A3E0C); // the served legend's POV umber

      // A failed detail call leaves the rows the tile can give.
      final park = feats.singleWhere((f) => f.id == 102835);
      expect(hasRow(park, 'Vrsta', 'regijski park'), isTrue);
      expect(park.color, 0xFF80B537);
      final epo = feats.singleWhere((f) => f.id == 401);
      expect(epo.cls, '');
      expect(epo.color, 0xFFFBFB7F); // single-class legend row
    });

    test('TB-37: a natural monument is coloured from the ZO legend', () async {
      final feats = await ObmocjaStore(
        client: MockClient((_) async => http.Response('', 404)),
      ).identify(_lipe, {ZosKind.ns}, readTile: _readFixture, legend: _legend);

      final lipe = feats.singleWhere((f) => f.id == 101639);
      expect(lipe.kind, ZosKind.ns);
      expect(lipe.isPoint, isTrue);
      expect(lipe.ime, 'Korošičeve lipe v Frajhajmu');
      expect(lipe.color, 0xFFCD4E1B); // the legend's naravni-spomenik row
      expect(lipe.rows.any((e) => e.key == 'Vrsta'), isTrue);
      expect(feats.every((f) => f.kind == ZosKind.ns), isTrue);
    });

    test('nothing active reads no tile and returns nothing', () async {
      var read = false;
      final feats = await ObmocjaStore(
        client: MockClient((_) async => http.Response('', 500)),
      ).identify(_cerknica, <ZosKind>{}, readTile: (z, x, y) async {
        read = true;
        return null;
      });
      expect(feats, isEmpty);
      expect(read, isFalse);
    });

    test('a tile that cannot be read is an ObmocjaException', () async {
      final store =
          ObmocjaStore(client: MockClient((_) async => http.Response('', 200)));
      expect(
        store.identify(_cerknica, {ZosKind.n2k},
            readTile: (z, x, y) async => throw const SocketException('down')),
        throwsA(isA<ObmocjaException>()),
      );
    });
  });
}
