// Unit tests for ObmocjaStore.identify — the WMS GetFeatureInfo "identify"
// across the active "Območja s statusom" sublayers. MockClient feeds a canned
// GetFeatureInfo FeatureCollection with one feature per sublayer (the real
// attribute schemas), so the production GeoServer is never touched.

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
          'id': 'ZOS_N2K_PLG.1275',
          'properties': {
            'IME_OBM': 'Cerkniško jezero',
            'KODA_OBM': 'SI5000015',
            'N2K_TIP_OBMOCJA': 'POV',
            'N2K_BIOGEO_REGION': 'celinska',
            'OPIS': 'Presihajoče jezero …',
            'POV_HA': 2620.5,
            'DAT_ZAC': '2013-04-20T00:00:00Z',
          },
        },
        {
          'id': 'ZOS_ZO_PLG.102835',
          'properties': {
            'IME_OBM': 'Notranjski regijski park',
            'KODA_OBM': '102835',
            'ZO_VRSTA': 'regijski park',
            'ZO_POMEN': 'lokalni',
            'CITAT': 'Ur. l. RS …',
            'POV_HA': 22270,
          },
        },
        {
          'id': 'ZOS_EPO_PLG.401',
          'properties': {
            'IME_OBM': 'Notranjski trikotnik',
            'KODA_OBM': '401',
            'OPIS': 'Ekološko pomembno območje …',
            'POV_HA': 52000,
          },
        },
        {
          'id': 'ZOS_NV_PLG.20957',
          'properties': {
            'IME_OBM': 'Cerkniško polje',
            'KODA_OBM': '367V',
            'NV_POMEN': 'državni',
            'NV_ZVRSTI': 'geomorfološka',
            'NV_KRATKA_OZNAKA': 'Kraško polje …',
            'POV_HA': 2600,
          },
        },
        {
          'id': 'ZOS_NV_PNT_JAME.42',
          'properties': {
            'IME_OBM': 'Križna jama',
            'KODA_OBM': '855',
            'NV_POMEN': 'državni',
            'NV_KRATKA_OZNAKA': 'Vodna jama …',
          },
        },
      ],
    });

void main() {
  group('ObmocjaStore.identify', () {
    test('queries the active sublayers and tags features by kind', () async {
      late Uri seen;
      final store = ObmocjaStore(
        client: MockClient((req) async {
          seen = req.url;
          return http.Response.bytes(utf8.encode(_gfi()), 200);
        }),
      );

      final feats = await store.identify(
        const LatLng(45.77, 14.37),
        {ZosKind.n2k, ZosKind.zo, ZosKind.epo, ZosKind.nv, ZosKind.nvj},
      );

      // QUERY_LAYERS carries the active layer names.
      final ql = seen.queryParameters['QUERY_LAYERS']!;
      expect(ql, contains('SI.NARCIS:ZOS_N2K_PLG'));
      expect(ql, contains('SI.NARCIS:ZOS_ZO_PLG'));
      expect(ql, contains('SI.NARCIS:ZOS_NV_PNT_JAME'));

      // Each feature tagged with the right sublayer (NV vs jame disambiguated).
      expect(feats.map((f) => f.kind).toList(),
          [ZosKind.n2k, ZosKind.zo, ZosKind.epo, ZosKind.nv, ZosKind.nvj]);

      bool hasRow(ObmocjeFeature f, String label, String value) =>
          f.rows.any((e) => e.key == label && e.value == value);

      final n2k = feats[0];
      expect(n2k.ime, 'Cerkniško jezero');
      expect(n2k.tip, 'POV');
      expect(hasRow(n2k, 'Tip', 'POV'), isTrue);

      final zo = feats[1];
      expect(hasRow(zo, 'Vrsta', 'regijski park'), isTrue);

      final nv = feats[3];
      expect(nv.opis, 'Kraško polje …'); // NV_KRATKA_OZNAKA as description
      expect(hasRow(nv, 'Pomen', 'državni'), isTrue);
    });

    test('empty active set issues no request and returns empty', () async {
      var called = false;
      final store = ObmocjaStore(
        client: MockClient((req) async {
          called = true;
          return http.Response('', 200);
        }),
      );
      final feats = await store.identify(const LatLng(46, 15), <ZosKind>{});
      expect(feats, isEmpty);
      expect(called, isFalse);
    });

    test('throws ObmocjaException on a network/HTTP failure', () async {
      final store = ObmocjaStore(
        client: MockClient((req) async => http.Response('boom', 500)),
      );
      expect(
        store.identify(const LatLng(46, 15), {ZosKind.n2k}),
        throwsA(isA<ObmocjaException>()),
      );
    });
  });
}
