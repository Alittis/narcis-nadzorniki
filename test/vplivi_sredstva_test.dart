// TB-42 (vplivi in posledice on a record) and TB-43 (sredstvo obhoda on a
// walk): the option order and the exclusive pair, the local stores, the wire
// both ways, and the Končaj obhod sheet that makes TB-43 required.
//
// The pull keeps both because AppState's merges rebuild every synced record
// and walk from `toLocal()`; the `toLocal` tests below are what pins that.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/option_lists.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/home_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

const _creds = SyncCredentials.token('t');
final _apiBase = Uri.parse('https://narcis.alittis.com/api/beleznica/app/v1');

Disturbance _record({List<String> impacts = const []}) => Disturbance(
      id: '11111111-2222-3333-4444-555555555555',
      latitude: 45.79,
      longitude: 14.36,
      locationAccuracy: 'Natančna',
      observedAt: DateTime.utc(2026, 11, 23, 9),
      types: const [],
      description: '',
      photos: const [],
      observers: const [],
      actionTaken: 'Brez ukrepa',
      caseStatus: 'Odprto',
      pendingSync: true,
      createdAt: DateTime.utc(2026, 11, 23, 9),
      impacts: impacts,
    );

Walk _walk({List<String> modes = const []}) => Walk(
      id: '66666666-7777-8888-9999-000000000000',
      startedAt: DateTime.utc(2026, 11, 23, 8),
      endedAt: DateTime.utc(2026, 11, 23, 9),
      pendingSync: true,
      points: [
        WalkPoint(
          seq: 0,
          latitude: 45.79,
          longitude: 14.36,
          timestamp: DateTime.utc(2026, 11, 23, 8),
        ),
      ],
      transportModes: modes,
    );

/// Captures the one request a call makes and answers [status] with [body].
({RemoteApi api, List<http.Request> sent}) _api(int status, Object body) {
  final sent = <http.Request>[];
  final api = RemoteApi(
    client: MockClient((req) async {
      sent.add(req);
      return http.Response.bytes(utf8.encode(jsonEncode(body)), status,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    apiBase: _apiBase,
    timeout: const Duration(seconds: 1),
  );
  return (api: api, sent: sent);
}

void main() {
  group('toggleInOrder', () {
    test('keeps the list order whatever the tapping order', () {
      var v = <String>[];
      for (final x in ['Okrnjena krajina', 'Splašene in vznemirjene živali']) {
        v = toggleInOrder(v, x, kDisturbanceImpacts);
      }
      expect(v, ['Splašene in vznemirjene živali', 'Okrnjena krajina']);
    });

    test('a second tap unticks', () {
      expect(toggleInOrder(['Peš', 'Kolo'], 'Peš', kWalkTransportModes), ['Kolo']);
    });

    test('the exclusive pair: ticking one drops the other (TB-42)', () {
      final a = toggleInOrder(
        ['Poškodovan habitat', 'Kršen varstveni režim'],
        'Domnevna kršitev varstvenega režima',
        kDisturbanceImpacts,
        exclusive: kExclusiveImpacts,
      );
      expect(a, ['Poškodovan habitat', 'Domnevna kršitev varstvenega režima']);
      final b = toggleInOrder(a, 'Kršen varstveni režim', kDisturbanceImpacts,
          exclusive: kExclusiveImpacts);
      expect(b, ['Poškodovan habitat', 'Kršen varstveni režim']);
    });

    test('a value outside the list is kept, after the known ones', () {
      expect(toggleInOrder(['Star vpliv'], 'Poškodovan habitat', kDisturbanceImpacts),
          ['Poškodovan habitat', 'Star vpliv']);
    });
  });

  group('local stores', () {
    test('a record keeps its impacts through toJson/fromJson', () {
      final r = Disturbance.fromJson(
          jsonDecode(jsonEncode(_record(impacts: ['Onesnaženje okolja']).toJson()))
              as Map<String, dynamic>);
      expect(r.impacts, ['Onesnaženje okolja']);
    });

    test('a record cached before TB-42 reads as none stated', () {
      final json = _record().toJson()..remove('impacts');
      expect(Disturbance.fromJson(json).impacts, isEmpty);
    });

    test('a walk keeps its means of transport; one from before TB-43 has none',
        () {
      final w = Walk.fromJson(jsonDecode(jsonEncode(_walk(modes: ['Avto', 'Peš']).toJson()))
          as Map<String, dynamic>);
      expect(w.transportModes, ['Avto', 'Peš']);
      expect(Walk.fromJson(_walk().toJson()..remove('transportModes')).transportModes,
          isEmpty);
    });

    test('copyWith keeps both unless told otherwise', () {
      expect(_record(impacts: ['Okrnjena krajina']).copyWith(pendingSync: false).impacts,
          ['Okrnjena krajina']);
      expect(_walk(modes: ['Čoln']).copyWith(pendingSync: false).transportModes, ['Čoln']);
    });
  });

  group('the wire', () {
    test('a record POST carries impacts once chosen, and omits the key when none', () async {
      final c = _api(201, {'id': 'x', 'status': 'created'});
      await c.api.createRecord(_record(impacts: ['Poškodovan habitat']), _creds);
      await c.api.createRecord(_record(), _creds);
      final withIt = jsonDecode(c.sent[0].body) as Map<String, dynamic>;
      final without = jsonDecode(c.sent[1].body) as Map<String, dynamic>;
      expect(withIt['impacts'], ['Poškodovan habitat']);
      expect(without.containsKey('impacts'), isFalse);
    });

    test('a walk POST carries transportModes', () async {
      final c = _api(201, {'id': 'x', 'status': 'created'});
      await c.api.createWalk(_walk(modes: ['Peš', 'Dron']), _creds);
      final body = jsonDecode(c.sent.single.body) as Map<String, dynamic>;
      expect(body['transportModes'], ['Peš', 'Dron']);
    });

    test('the record list: impacts read, and carried into the local record', () async {
      final c = _api(200, {
        'records': [
          {
            'id': 'r1',
            'latitude': 45.79,
            'longitude': 14.36,
            'locationAccuracy': 'Natančna',
            'observedAt': '2026-11-23T09:00:00.000Z',
            'actionTaken': 'Brez ukrepa',
            'types': [],
            'observers': [],
            'photos': [],
            'impacts': ['Okrnjena krajina', 'Onesnaženje okolja'],
          },
          {
            'id': 'r2',
            'latitude': 45.79,
            'longitude': 14.36,
            'locationAccuracy': 'Natančna',
            'observedAt': '2026-11-23T09:00:00.000Z',
            'actionTaken': 'Brez ukrepa',
          },
        ],
      });
      final list = (await c.api.fetchRecords(_creds)).items;
      expect(list[0].toLocal().impacts, ['Okrnjena krajina', 'Onesnaženje okolja']);
      expect(list[1].toLocal().impacts, isEmpty, reason: 'absent = none stated');
    });

    test('the walk list: transportModes read, and carried into the local walk', () async {
      final c = _api(200, {
        'walks': [
          {
            'id': 'w1',
            'startedAt': '2026-11-23T08:00:00.000Z',
            'endedAt': '2026-11-23T09:00:00.000Z',
            'pointCount': 1,
            'disturbanceCount': 0,
            'transportModes': ['Kolo'],
          },
        ],
      });
      final list = (await c.api.fetchWalks(_creds)).items;
      expect(list.single.toLocal().transportModes, ['Kolo']);
    });
  });

  group('a narrow phone, large text (no emulator run covers these)', () {
    // 320 dp at text scale 1.3: narrower and larger than the wardens' phones.
    // A RenderFlex overflow fails the test instead of printing a stripe.
    void narrow(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('Končaj obhod with every means ticked', (tester) async {
      narrow(tester);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showModalBottomSheet<EndWalkResult>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const EndWalkSheet(pointCount: 12),
              ),
              child: const Text('konec'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('konec'));
      await tester.pumpAndSettle();
      for (final m in kWalkTransportModes) {
        await tester.ensureVisible(find.widgetWithText(FilterChip, m));
        await tester.tap(find.widgetWithText(FilterChip, m));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(FilledButton, 'Shrani'), findsOneWidget);
    });

    testWidgets('the record preview with the longest impacts', (tester) async {
      narrow(tester);
      await tester.pumpWidget(ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          home: DetailScreen(
            record: _record(impacts: [
              'Splašene in vznemirjene živali',
              'Poškodovana naravna vrednota',
              'Domnevna kršitev varstvenega režima',
            ]),
            preview: true,
            onSave: () async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Domnevna kršitev varstvenega režima'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Končaj obhod (TB-43: required, nothing preselected)', () {
    Future<EndWalkResult?> openSheet(WidgetTester tester) async {
      EndWalkResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async => result = await showModalBottomSheet<EndWalkResult>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const EndWalkSheet(pointCount: 12),
              ),
              child: const Text('konec'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('konec'));
      await tester.pumpAndSettle();
      return result;
    }

    FilledButton shrani(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Shrani'));

    testWidgets('Shrani stays disabled until a means is chosen', (tester) async {
      await openSheet(tester);
      for (final m in kWalkTransportModes) {
        expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, m)).selected,
            isFalse, reason: '$m must not be preselected');
      }
      expect(shrani(tester).onPressed, isNull);

      await tester.tap(find.widgetWithText(FilterChip, 'Kolo'));
      await tester.pump();
      expect(shrani(tester).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilterChip, 'Kolo'));
      await tester.pump();
      expect(shrani(tester).onPressed, isNull, reason: 'unticking the last one disables it again');
    });

    testWidgets('the chosen means come back in the list order', (tester) async {
      EndWalkResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async => result = await showModalBottomSheet<EndWalkResult>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const EndWalkSheet(pointCount: 12),
              ),
              child: const Text('konec'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('konec'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilterChip, 'Dron'));
      await tester.tap(find.widgetWithText(FilterChip, 'Peš'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Shrani'));
      await tester.pumpAndSettle();

      expect(result?.discard, isFalse);
      expect(result?.transportModes, ['Peš', 'Dron']);
    });
  });
}
