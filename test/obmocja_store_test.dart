// Unit tests for ObmocjaStore.identify — the WMS GetFeatureInfo "identify"
// against the production NarcIS GeoServer. MockClient feeds a canned
// GetFeatureInfo FeatureCollection (the real Cerknica response shape, where a
// tap hits two overlapping Natura areas: an SPA/POV and an SAC/POO), so the
// real GeoServer is never touched.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

String _gfi() => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'id': 'ZOS_N2K_PLG.1275',
          'properties': {
            'IME_OBM': 'Cerkniško jezero',
            'KODA_OBM': 'SI5000015',
            'N2K_TIP_OBMOCJA': 'POV',
            'N2K_BIOGEO_REGION': 'celinska',
            'OPIS': 'Presihajoče Cerkniško jezero …',
            'POV_HA': 2620.5,
            'DAT_ZAC': '2013-04-20T00:00:00Z',
          },
        },
        {
          'type': 'Feature',
          'id': 'ZOS_N2K_PLG.1263',
          'properties': {
            'IME_OBM': 'Notranjski trikotnik',
            'KODA_OBM': 'SI3000232',
            'N2K_TIP_OBMOCJA': 'POO',
            'N2K_BIOGEO_REGION': 'celinska',
            'OPIS': 'Območje s podzemnim svetom …',
            'POV_HA': 52000,
            'DAT_ZAC': '2013-04-20T00:00:00Z',
          },
        },
      ],
    });

void main() {
  group('ObmocjaStore.identify', () {
    test('issues a GetFeatureInfo and parses overlapping features', () async {
      late Uri seen;
      final store = ObmocjaStore(
        client: MockClient((req) async {
          seen = req.url;
          return http.Response.bytes(utf8.encode(_gfi()), 200);
        }),
      );

      final feats = await store.identify(const LatLng(45.77, 14.37));

      // Request shape.
      expect(seen.queryParameters['REQUEST'], 'GetFeatureInfo');
      expect(seen.queryParameters['QUERY_LAYERS'], 'SI.NARCIS:ZOS_N2K_PLG');
      expect(seen.queryParameters['INFO_FORMAT'], 'application/json');

      // Both overlapping areas, with attributes + designation parsed.
      expect(feats, hasLength(2));
      expect(feats[0].ime, 'Cerkniško jezero');
      expect(feats[0].isPov, isTrue); // SI5… / POV
      expect(feats[0].povrsinaHa, 2620.5);
      expect(feats[0].datZac, '2013-04-20'); // ISO time trimmed
      expect(feats[1].ime, 'Notranjski trikotnik');
      expect(feats[1].isPov, isFalse); // SI3… / POO
    });

    test('returns empty when the point is on no area', () async {
      final store = ObmocjaStore(
        client: MockClient((req) async => http.Response.bytes(
              utf8.encode('{"type":"FeatureCollection","features":[]}'),
              200,
            )),
      );
      expect(await store.identify(const LatLng(46.0, 15.0)), isEmpty);
    });

    test('throws ObmocjaException on a network/HTTP failure', () async {
      final store = ObmocjaStore(
        client: MockClient((req) async => http.Response('boom', 500)),
      );
      expect(
        store.identify(const LatLng(46.0, 15.0)),
        throwsA(isA<ObmocjaException>()),
      );
    });
  });
}
