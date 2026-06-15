// Unit tests for ObmocjaStore: ORDS envelope parsing, EPSG:3794 -> WGS84
// reprojection, session caching, and the tap-to-identify point-in-polygon test.
//
// MockClient (package:http/testing.dart) feeds a canned ORDS envelope, so the
// real narcis.gov.si endpoint is never touched. The reprojection golden value
// is a real vertex captured from both the raw 3794 ORDS output and the
// reprojected 4326 output of narcis-vibed (feature 215): the 3794 pair
// (418417.671502, 118453.695236) maps to WGS84 (13.942885, 46.200951).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

/// ORDS wraps a stringified FeatureCollection in `{items:[{geojson}]}`. This
/// envelope carries one POO polygon whose first vertex is the golden 3794 pair.
String _envelope() {
  final fc = jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'id': 215,
        'properties': {
          'IME_OBM': 'Ježevec',
          'KODA_OBM': 'SI3000006',
          'N2K_TIP_OBMOCJA': 'POO',
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              [418417.671502, 118453.695236],
              [419000.0, 118453.695236],
              [419000.0, 119000.0],
              [418417.671502, 119000.0],
              [418417.671502, 118453.695236],
            ],
          ],
        },
      },
    ],
  });
  return jsonEncode({
    'items': [
      {'geojson': fc},
    ],
  });
}

void main() {
  group('ObmocjaStore.loadN2k', () {
    test('parses the ORDS envelope and reprojects 3794 -> WGS84', () async {
      final store = ObmocjaStore(
        client: MockClient((req) async {
          expect(req.url.toString(), endsWith('/vib/zos/N2k'));
          return http.Response.bytes(utf8.encode(_envelope()), 200);
        }),
      );

      final areas = await store.loadN2k();

      expect(areas, hasLength(1));
      final a = areas.single;
      expect(a.id, 215);
      expect(a.ime, 'Ježevec');
      expect(a.koda, 'SI3000006');
      expect(a.tip, 'POO');
      expect(a.isPov, isFalse);
      expect(a.parts, hasLength(1));

      final first = a.parts.single.outer.first;
      expect(first.latitude, closeTo(46.200951, 1e-4));
      expect(first.longitude, closeTo(13.942885, 1e-4));
    });

    test('caches after first load — a second call hits no network', () async {
      var calls = 0;
      final store = ObmocjaStore(
        client: MockClient((req) async {
          calls++;
          return http.Response.bytes(utf8.encode(_envelope()), 200);
        }),
      );

      final a1 = await store.loadN2k();
      final a2 = await store.loadN2k();

      expect(calls, 1);
      expect(identical(a1, a2), isTrue);
      expect(store.isLoaded, isTrue);
    });

    test('non-200 throws ObmocjaException', () async {
      final store = ObmocjaStore(
        client: MockClient((req) async => http.Response('boom', 500)),
      );
      expect(store.loadN2k(), throwsA(isA<ObmocjaException>()));
    });
  });

  group('areaAtPoint', () {
    final square = N2kArea(
      id: 1,
      ime: 'Sq',
      koda: 'X',
      tip: 'POO',
      parts: [
        N2kPart(
          outer: [
            const LatLng(46.0, 14.0),
            const LatLng(46.0, 14.1),
            const LatLng(46.1, 14.1),
            const LatLng(46.1, 14.0),
            const LatLng(46.0, 14.0),
          ],
        ),
      ],
    );

    test('returns the area for an interior point', () {
      expect(areaAtPoint([square], const LatLng(46.05, 14.05))?.id, 1);
    });

    test('returns null for an exterior point', () {
      expect(areaAtPoint([square], const LatLng(45.5, 13.0)), isNull);
    });
  });
}
