// TB-39 phase 1, the phone half of narcis-vibed NV-622: hot spots (*vroče
// točke*). The phone lists the org's hot spots, files a NEW record on one, and
// lists a hot spot's records.
//
// What the server half fixed, and these tests hold the phone to:
// - `GET hotspots` → `{"hotspots":[{id,name,latitude,longitude,…}]}`.
// - A record's `hotspotId`, absent when none, both ways. A linked record still
//   sends the warden's OWN latitude/longitude (owner, 2026-11-25).
// - POST naming a hot spot the server does not know for the org → 400
//   `{"error":"unknown_hotspot"}`. The phone keeps a record queued on any
//   failure, so without the drop-and-resend here a hot spot lost in a restore
//   would strand the record for ever.

import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/dataset_generation_store.dart';
import 'package:narcis_nadzorniki/data/hotspots_store.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/tezave_store.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/hotspot.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/form_screen.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:narcis_nadzorniki/widgets/hotspot_sheet.dart';
import 'package:provider/provider.dart';

const _base = '/api/beleznica/app/v1';
final _apiBase = Uri.parse('https://narcis.alittis.com$_base');
const _creds = SyncCredentials.token('tok');

const _hsId = '0b6c1e5a-3f0e-4d8e-9a51-1c2d3e4f5a6b';
const _otherHsId = '9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a';

/// Zadrževalnik Rešeto, ~450 m north of where the warden stands.
const _hotspot = Hotspot(
  id: _hsId,
  name: 'Zadrževalnik Rešeto',
  latitude: 45.794,
  longitude: 14.36,
);

/// Where the warden stood: NOT the hot spot's point.
const _fix = LatLng(45.79, 14.36);

const _type = SelectedDisturbanceType(
  groupCode: 'G1',
  groupName: 'Vožnja v naravnem okolju',
  typeCode: 'T1',
  typeName: 'Vožnja z motornim vozilom',
);

Disturbance _rec(
  String id, {
  String? hotspotId,
  bool pendingSync = true,
  DateTime? observedAt,
  String typeName = 'Vožnja z motornim vozilom',
}) =>
    Disturbance(
      id: id,
      latitude: _fix.latitude,
      longitude: _fix.longitude,
      locationAccuracy: 'Natančna',
      observedAt: observedAt ?? DateTime.utc(2026, 11, 25, 9),
      types: [
        SelectedDisturbanceType(
          groupCode: 'G1',
          groupName: 'Vožnja v naravnem okolju',
          typeCode: 'T1',
          typeName: typeName,
        ),
      ],
      description: '',
      photos: const [],
      observers: const [],
      actionTaken: 'Brez ukrepa',
      caseStatus: 'Odprto',
      pendingSync: pendingSync,
      createdAt: DateTime.utc(2026, 11, 25, 9),
      createdBy: 'warden@gov.si',
      hotspotId: hotspotId,
    );

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

RemoteApi _api(Future<http.Response> Function(http.Request) respond) =>
    RemoteApi(
      client: MockClient(respond),
      apiBase: _apiBase,
      timeout: const Duration(seconds: 1),
    );

// ---------------------------------------------------------------- fakes ----

class _MemStore extends LocalStore {
  List<Disturbance> saved = [];
  @override
  Future<List<Disturbance>> load() async => saved;
  @override
  Future<void> save(List<Disturbance> items) async => saved = items;
}

class _MemWalksStore extends WalksLocalStore {
  @override
  Future<List<Walk>> load() async => const [];
  @override
  Future<void> save(List<Walk> walks) async {}
  @override
  Future<Walk?> loadActive() async => null;
  @override
  Future<void> clearActive() async {}
}

class _MemHotspotsStore extends HotspotsStore {
  _MemHotspotsStore([this.saved = const []]);
  List<Hotspot> saved;
  @override
  Future<List<Hotspot>> load() async => saved;
  @override
  Future<void> save(List<Hotspot> hotspots) async => saved = hotspots;
}

class _FakeAuth extends AuthService {
  _FakeAuth({this.signedIn = true});
  final bool signedIn;
  @override
  Future<StoredSession?> readStoredSession() async => signedIn
      ? const StoredSession(email: 'warden@gov.si', token: 'tok')
      : null;
  @override
  Future<void> revokeToken(String token) async {}
  @override
  Future<void> clearCache() async {}
}

class _Connectivity implements Connectivity {
  _Connectivity(this.online);
  final bool online;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [online ? ConnectivityResult.wifi : ConnectivityResult.none];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

Future<Directory> _noDocuments() =>
    Future.error(UnsupportedError('no documents dir'));

/// A stub of the field-app API that knows [known] hot spots, as the server
/// half decides: a POST naming any other is 400 `unknown_hotspot`.
class _Server {
  _Server({Set<String>? known, List<Map<String, dynamic>>? list})
      : known = known ?? {_hsId},
        list = list ?? [_hotspot.toJson()];

  final Set<String> known;
  List<Map<String, dynamic>> list;
  int hotspotsStatus = 200;

  /// When set, every record POST is refused with this 400 error instead.
  String? refuseWith;
  final posts = <Map<String, dynamic>>[];
  final records = <String, Map<String, dynamic>>{};

  Future<http.Response> handle(http.Request req) async {
    final p = req.url.pathSegments.sublist(4);
    switch ((req.method, p)) {
      case ('GET', ['hotspots']):
        if (hotspotsStatus != 200) return http.Response('', hotspotsStatus);
        return _json({'hotspots': list});
      case ('GET', ['disturbances']):
        return _json({'records': records.values.toList()});
      case ('GET', ['walks']):
        return _json({'walks': <dynamic>[]});
      case ('POST', ['disturbances']):
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        posts.add(b);
        if (refuseWith != null) return _json({'error': refuseWith}, 400);
        final hs = b['hotspotId'] as String?;
        if (hs != null && !known.contains(hs)) {
          return _json({'error': 'unknown_hotspot'}, 400);
        }
        records[b['id'] as String] = {
          ...b..removeWhere((_, v) => v == null),
          'createdAt': b['observedAt'],
          'createdBy': 'warden@gov.si',
        };
        return _json({'id': b['id'], 'status': 'created'}, 201);
      case ('POST', ['tezave']):
        return http.Response('', 204);
    }
    return _json({'error': 'not_found'}, 404);
  }
}

/// A booted, signed-in, online AppState against [server].
Future<AppState> _boot(
  _Server server, {
  required _MemStore store,
  required HotspotsStore hotspots,
  required Directory tmp,
}) async {
  final state = AppState(
    localStore: store,
    walksStore: _MemWalksStore(),
    remoteApi: RemoteApi(
      client: MockClient(server.handle),
      apiBase: _apiBase,
      timeout: const Duration(seconds: 2),
    ),
    connectivity: _Connectivity(true),
    authService: _FakeAuth(),
    photoStorage:
        PhotoStorage(rootResolver: () => Directory('${tmp.path}/photos')),
    generationStore: DatasetGenerationStore(directory: _noDocuments),
    tezaveStore: TezaveStore(directory: _noDocuments),
    hotspotsStore: hotspots,
  );
  await state.init();
  await pumpEventQueue();
  return state;
}

/// An offline AppState with [hotspots] in its cache, for the widget tests.
/// Everything is in memory: under testWidgets a real file never answers.
Future<AppState> _bootOffline(List<Hotspot> hotspots) async {
  final state = AppState(
    localStore: _MemStore(),
    walksStore: _MemWalksStore(),
    connectivity: _Connectivity(false),
    authService: _FakeAuth(signedIn: false),
    generationStore: DatasetGenerationStore(directory: _noDocuments),
    tezaveStore: TezaveStore(directory: _noDocuments),
    hotspotsStore: _MemHotspotsStore(hotspots),
  );
  await state.init();
  return state;
}

const _geolocator = MethodChannel('flutter.baseflow.com/geolocator');

/// The hot spot drawn on the picker's map (the bar under it has its own).
final _onMap = find.descendant(
  of: find.byType(FlutterMap),
  matching: find.byType(HotspotMarker),
);
const _fgs = MethodChannel('flutter_foreground_task/methods');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the wire', () {
    test('a record\'s hotspotId is read from the list and kept by toLocal', () {
      final remote = RemoteDisturbance.fromJson({
        'id': 'r1',
        'latitude': 45.79,
        'longitude': 14.36,
        'locationAccuracy': 'Natančna',
        'observedAt': '2026-11-25T09:00:00Z',
        'actionTaken': 'Brez ukrepa',
        'hotspotId': _hsId,
      });
      expect(remote.hotspotId, _hsId);
      // The merge rebuilds every synced record from toLocal(): dropping the
      // key there would strip every link on the first pull.
      expect(remote.toLocal().hotspotId, _hsId);
    });

    test('a record without the key is on no hot spot', () {
      final remote = RemoteDisturbance.fromJson({
        'id': 'r1',
        'latitude': 45.79,
        'longitude': 14.36,
        'locationAccuracy': 'Natančna',
        'observedAt': '2026-11-25T09:00:00Z',
        'actionTaken': 'Brez ukrepa',
      });
      expect(remote.toLocal().hotspotId, isNull);
    });

    test('a linked record sends the id and the warden\'s own position',
        () async {
      final sent = <Map<String, dynamic>>[];
      await _api((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return _json({'status': 'created'}, 201);
      }).createRecord(_rec('r1', hotspotId: _hsId), _creds);
      expect(sent.single['hotspotId'], _hsId);
      expect(sent.single['latitude'], _fix.latitude);
      expect(sent.single['longitude'], _fix.longitude);
    });

    test('a record on no hot spot sends no key at all', () async {
      final sent = <Map<String, dynamic>>[];
      await _api((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return _json({'status': 'created'}, 201);
      }).createRecord(_rec('r1'), _creds);
      expect(sent.single.containsKey('hotspotId'), isFalse);
    });

    test('GET hotspots: the list, minus what cannot be drawn', () async {
      late http.Request seen;
      final list = await _api((req) async {
        seen = req;
        return _json({
          'hotspots': [
            {
              'id': _hsId,
              'name': 'Zadrževalnik Rešeto',
              'latitude': 45.794,
              'longitude': 14.36,
              'createdAt': '2026-11-25T09:00:00Z',
              'createdBy': 'admin@gov.si',
            },
            {'id': _otherHsId, 'name': 'Brez koordinat'},
            'not a map',
          ],
        });
      }).fetchHotspots(_creds);
      expect(seen.method, 'GET');
      expect(seen.url.path, '$_base/hotspots');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['X-App-Build'], isNotNull);
      expect(list, hasLength(1));
      expect(list.single.id, _hsId);
      expect(list.single.name, 'Zadrževalnik Rešeto');
      expect(list.single.latitude, 45.794);
    });

    test('a body without the list is an error, so the cache is kept',
        () async {
      for (final body in ['{"records":[]}', 'not json']) {
        await expectLater(
          _api((_) async => http.Response(body, 200)).fetchHotspots(_creds),
          throwsA(isA<RemoteApiException>()),
          reason: body,
        );
      }
    });

    test('the failure count folds the route to /hotspots, not :id', () {
      final api = _api((_) async => http.Response('', 200));
      expect(api.foldPath(_apiBase.replace(path: '$_base/hotspots')),
          '$_base/hotspots');
    });

    test('only a 400 unknown_hotspot counts as an unknown hot spot', () {
      bool unknown(int status, String? body) =>
          RemoteApiException(statusCode: status, body: body).isUnknownHotspot;
      expect(unknown(400, '{"error":"unknown_hotspot"}'), isTrue);
      expect(unknown(400, '{"error":"bad_json"}'), isFalse);
      expect(unknown(500, '{"error":"unknown_hotspot"}'), isFalse);
      expect(unknown(400, 'unknown_hotspot'), isFalse);
      expect(unknown(400, null), isFalse);
      expect(RemoteApiException(cause: 'offline').isUnknownHotspot, isFalse);
    });
  });

  group('the local copies', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tb39_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a record keeps its hot spot through the local store', () {
      final back =
          Disturbance.fromJson(_rec('r1', hotspotId: _hsId).toJson());
      expect(back.hotspotId, _hsId);
    });

    test('a record cached before TB-39 reads as on no hot spot', () {
      final json = _rec('r1').toJson()..remove('hotspotId');
      expect(Disturbance.fromJson(json).hotspotId, isNull);
    });

    test('copyWith keeps the link unless told to clear it', () {
      final r = _rec('r1', hotspotId: _hsId);
      expect(r.copyWith(pendingSync: false).hotspotId, _hsId);
      expect(r.copyWith(clearHotspotId: true).hotspotId, isNull);
    });

    test('the hot-spot cache round-trips, and reads empty when absent or bad',
        () async {
      final store = HotspotsStore(directory: () async => tmp);
      expect(await store.load(), isEmpty);
      await store.save([_hotspot]);
      final back = await store.load();
      expect(back.single.id, _hsId);
      expect(back.single.name, 'Zadrževalnik Rešeto');
      File('${tmp.path}/hotspots.json').writeAsStringSync('{not json');
      expect(await store.load(), isEmpty);
    });
  });

  group('AppState', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tb39_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        _fgs,
        (call) async => call.method == 'isRunningService' ? false : null,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_fgs, null);
      tmp.deleteSync(recursive: true);
    });

    test('a sync pulls the hot spots and keeps them on the device', () async {
      final disk = HotspotsStore(directory: () async => tmp);
      final state = await _boot(_Server(),
          store: _MemStore(), hotspots: disk, tmp: tmp);
      expect(state.hotspots.single.name, 'Zadrževalnik Rešeto');
      expect(state.hotspotById(_hsId)?.name, 'Zadrževalnik Rešeto');
      expect(state.hotspotById(_otherHsId), isNull);
      expect((await disk.load()).single.id, _hsId);
    });

    test('a failed hot-spot pull keeps the list it had', () async {
      final server = _Server();
      final state = await _boot(server,
          store: _MemStore(), hotspots: _MemHotspotsStore(), tmp: tmp);
      expect(state.hotspots, hasLength(1));
      server.hotspotsStatus = 503;
      await state.syncAll();
      expect(state.hotspots, hasLength(1));
    });

    test('the pull keeps a listed record\'s hot spot', () async {
      final server = _Server();
      server.records['r1'] = {
        'id': 'r1',
        'latitude': 45.79,
        'longitude': 14.36,
        'locationAccuracy': 'Natančna',
        'observedAt': '2026-11-25T09:00:00Z',
        'actionTaken': 'Brez ukrepa',
        'createdBy': 'colleague@gov.si',
        'hotspotId': _hsId,
      };
      final state = await _boot(server,
          store: _MemStore(), hotspots: _MemHotspotsStore(), tmp: tmp);
      expect(state.records.single.hotspotId, _hsId);
    });

    test('a linked record goes out with the warden\'s own position',
        () async {
      final server = _Server();
      final state = await _boot(server,
          store: _MemStore(), hotspots: _MemHotspotsStore(), tmp: tmp);
      await state.addRecord(_rec('r1', hotspotId: _hsId));
      final body = server.posts.single;
      expect(body['hotspotId'], _hsId);
      expect(body['latitude'], _fix.latitude, reason: 'not the hot spot\'s');
      expect(body['longitude'], _fix.longitude);
      expect(state.records.single.pendingSync, isFalse);
      expect(state.records.single.hotspotId, _hsId);
    });

    test('a hot spot the server does not know: the record goes without it',
        () async {
      // A hot spot this phone cached, lost on the server in a restore.
      final server = _Server(known: {});
      final store = _MemStore();
      final state = await _boot(server,
          store: store, hotspots: _MemHotspotsStore(), tmp: tmp);
      await state.addRecord(_rec('r1', hotspotId: _hsId));

      expect(server.posts, hasLength(2));
      expect(server.posts.first['hotspotId'], _hsId);
      expect(server.posts.last.containsKey('hotspotId'), isFalse);
      expect(server.posts.last['latitude'], _fix.latitude);
      final r = state.records.single;
      expect(r.pendingSync, isFalse, reason: 'sent, not stranded');
      expect(r.hotspotId, isNull);
      expect(store.saved.single.hotspotId, isNull, reason: 'persisted');
    });

    test('control: any other 400 keeps the record queued AND linked',
        () async {
      final server = _Server()..refuseWith = 'bad_json';
      final state = await _boot(server,
          store: _MemStore(), hotspots: _MemHotspotsStore(), tmp: tmp);
      await state.addRecord(_rec('r1', hotspotId: _hsId));
      expect(server.posts, hasLength(1), reason: 'no resend');
      expect(state.records.single.pendingSync, isTrue);
      expect(state.records.single.hotspotId, _hsId);
    });

    test('a hot spot missing from the cached list is still sent', () async {
      // Only the server's 400 may unlink: the list can lag behind the server.
      final server = _Server(list: []);
      final state = await _boot(server,
          store: _MemStore(), hotspots: _MemHotspotsStore(), tmp: tmp);
      expect(state.hotspots, isEmpty);
      await state.addRecord(_rec('r1', hotspotId: _hsId));
      expect(server.posts.single['hotspotId'], _hsId);
      expect(state.records.single.hotspotId, _hsId);
    });

    test('logout forgets the org\'s hot spots', () async {
      final disk = HotspotsStore(directory: () async => tmp);
      final state = await _boot(_Server(),
          store: _MemStore(), hotspots: disk, tmp: tmp);
      expect(state.hotspots, isNotEmpty);
      await state.logout();
      expect(state.hotspots, isEmpty);
      expect(await disk.load(), isEmpty);
    });
  });

  group('the record form and the picker', () {
    setUp(() {
      // No location service in the test host: the picker's own GPS read
      // comes back empty, as on a phone with location off.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_geolocator, (call) async {
        if (call.method == 'isLocationServiceEnabled') return false;
        return null;
      });
    });

    Future<void> openForm(
      WidgetTester tester,
      AppState state, {
      String? hotspotId,
    }) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => FormScreen(
                        initialLocation: _fix,
                        initialObservers: const [],
                        mapCenter: _fix,
                        initialBasemap: BasemapMode.osm,
                        initialTypes: const [_type],
                        initialHotspotId: hotspotId,
                      ),
                    ),
                  ),
                  child: const Text('domov'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('domov'));
      await tester.pumpAndSettle();
    }

    Future<void> scrollTo(WidgetTester tester, Finder f) async {
      await tester.scrollUntilVisible(f, 300,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    Future<Disturbance> save(WidgetTester tester, AppState state) async {
      await scrollTo(tester, find.text('Preglej in shrani'));
      await tester.tap(find.text('Preglej in shrani'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shrani zapis'));
      await tester.pumpAndSettle();
      return state.records.single;
    }

    testWidgets(
        'a tap on a hot spot in the picker files the record on it, '
        'and the record keeps the warden\'s position', (tester) async {
      final state = await _bootOffline([_hotspot]);
      await openForm(tester, state);
      await scrollTo(tester, find.text('Karta'));
      expect(find.text('Vročo točko izbereš na karti.'), findsOneWidget);

      await tester.tap(find.text('Karta'));
      await tester.pumpAndSettle();
      expect(find.text('Tapni vročo točko, da nanjo vežeš zapis.'),
          findsOneWidget);

      await tester.tap(_onMap);
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsOneWidget);

      await tester.tap(find.text('Potrdi'));
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsOneWidget,
          reason: 'the form names it');

      final record = await save(tester, state);
      expect(record.hotspotId, _hsId);
      expect(record.latitude, _fix.latitude, reason: 'the pin did not move');
      expect(record.longitude, _fix.longitude);
      expect(record.locationAccuracy, 'Natančna', reason: 'not downgraded');
    });

    testWidgets(
        'a warden standing at the hot spot can still tap it: the pin on top '
        'of it does not take the tap', (tester) async {
      // The usual case in the field: the fix taken at "+" IS the hot spot.
      const here = Hotspot(
        id: _hsId,
        name: 'Zadrževalnik Rešeto',
        latitude: 45.79,
        longitude: 14.36,
      );
      final state = await _bootOffline([here]);
      await openForm(tester, state);
      await scrollTo(tester, find.text('Karta'));
      await tester.tap(find.text('Karta'));
      await tester.pumpAndSettle();

      await tester.tap(_onMap);
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsOneWidget);

      await tester.tap(find.text('Potrdi'));
      await tester.pumpAndSettle();
      final record = await save(tester, state);
      expect(record.hotspotId, _hsId);
      expect(record.latitude, _fix.latitude);
      expect(record.locationAccuracy, 'Natančna', reason: 'the pin stayed');
    });

    testWidgets('a second tap, or Odstrani, takes the hot spot off again',
        (tester) async {
      final state = await _bootOffline([_hotspot]);
      await openForm(tester, state);
      await scrollTo(tester, find.text('Karta'));
      await tester.tap(find.text('Karta'));
      await tester.pumpAndSettle();

      await tester.tap(_onMap);
      await tester.pumpAndSettle();
      await tester.tap(_onMap);
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsNothing);

      await tester.tap(_onMap);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odstrani'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Potrdi'));
      await tester.pumpAndSettle();

      expect((await save(tester, state)).hotspotId, isNull);
    });

    testWidgets('a record started on a hot spot can be taken off it in the '
        'form', (tester) async {
      final state = await _bootOffline([_hotspot]);
      await openForm(tester, state, hotspotId: _hsId);
      await scrollTo(tester, find.text('Vroča točka: Zadrževalnik Rešeto'));
      await tester.tap(find.byTooltip('Odstrani vročo točko'));
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsNothing);
      expect((await save(tester, state)).hotspotId, isNull);
    });

    testWidgets('a record started on a hot spot is saved on it',
        (tester) async {
      final state = await _bootOffline([_hotspot]);
      await openForm(tester, state, hotspotId: _hsId);
      final record = await save(tester, state);
      expect(record.hotspotId, _hsId);
      expect(record.latitude, _fix.latitude);
    });

    testWidgets('an org with no hot spots sees no hot-spot UI',
        (tester) async {
      final state = await _bootOffline(const []);
      await openForm(tester, state);
      await scrollTo(tester, find.text('Karta'));
      expect(find.text('Vročo točko izbereš na karti.'), findsNothing);
      await tester.tap(find.text('Karta'));
      await tester.pumpAndSettle();
      expect(_onMap, findsNothing);
      expect(find.text('Tapni vročo točko, da nanjo vežeš zapis.'),
          findsNothing);
    });
  });

  group('the detail view', () {
    Future<void> show(
        WidgetTester tester, AppState state, Disturbance record) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: DetailScreen(record: record)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('names the record\'s hot spot', (tester) async {
      final state = await _bootOffline([_hotspot]);
      await show(tester, state, _rec('r1', hotspotId: _hsId));
      expect(find.text('Vroča točka: Zadrževalnik Rešeto'), findsOneWidget);
    });

    testWidgets('says so even when the hot spot is not on this device',
        (tester) async {
      final state = await _bootOffline(const []);
      await show(tester, state, _rec('r1', hotspotId: _otherHsId));
      expect(find.text('Vroča točka: ni na seznamu'), findsOneWidget);
    });

    testWidgets('a record on no hot spot shows no hot-spot pill',
        (tester) async {
      final state = await _bootOffline([_hotspot]);
      await show(tester, state, _rec('r1'));
      expect(find.textContaining('Vroča točka'), findsNothing);
    });
  });

  group('the hot-spot sheet', () {
    test('counts in Slovene', () {
      expect(zapisovLabel(1), '1 zapis');
      expect(zapisovLabel(2), '2 zapisa');
      expect(zapisovLabel(3), '3 zapisi');
      expect(zapisovLabel(4), '4 zapisi');
      expect(zapisovLabel(5), '5 zapisov');
      expect(zapisovLabel(11), '11 zapisov');
      expect(zapisovLabel(101), '101 zapis');
      expect(zapisovLabel(102), '102 zapisa');
    });

    /// Pumps a page whose *odpri* opens the sheet; the closure reads what the
    /// sheet handed back.
    Future<HotspotEntry? Function()> pumpSheet(
        WidgetTester tester, AppState state) async {
      HotspotEntry? chosen;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    chosen = await showHotspotSheet(context, _hotspot);
                  },
                  child: const Text('odpri'),
                ),
              ),
            ),
          ),
        ),
      );
      return () => chosen;
    }

    testWidgets('lists its own records, newest first, and nothing else',
        (tester) async {
      final store = _MemStore()
        ..saved = [
          _rec('old',
              hotspotId: _hsId,
              observedAt: DateTime.utc(2026, 10, 1, 9),
              typeName: 'Stari zapis'),
          _rec('new',
              hotspotId: _hsId,
              observedAt: DateTime.utc(2026, 11, 20, 9),
              typeName: 'Novi zapis'),
          _rec('elsewhere', typeName: 'Drugje'),
          _rec('other-spot', hotspotId: _otherHsId, typeName: 'Druga točka'),
        ];
      final state = AppState(
        localStore: store,
        walksStore: _MemWalksStore(),
        connectivity: _Connectivity(false),
        authService: _FakeAuth(signedIn: false),
        generationStore: DatasetGenerationStore(directory: _noDocuments),
        tezaveStore: TezaveStore(directory: _noDocuments),
        hotspotsStore: _MemHotspotsStore([_hotspot]),
      );
      await state.init();
      await pumpSheet(tester, state);
      await tester.tap(find.text('odpri'));
      await tester.pumpAndSettle();

      expect(find.text('Zadrževalnik Rešeto'), findsOneWidget);
      expect(find.text('Vroča točka · 2 zapisa'), findsOneWidget);
      expect(find.text('Drugje'), findsNothing);
      expect(find.text('Druga točka'), findsNothing);
      final newer = tester.getTopLeft(find.text('Novi zapis')).dy;
      final older = tester.getTopLeft(find.text('Stari zapis')).dy;
      expect(newer, lessThan(older), reason: 'newest first');
    });

    testWidgets('a hot spot with no records yet says so', (tester) async {
      final state = await _bootOffline([_hotspot]);
      await pumpSheet(tester, state);
      await tester.tap(find.text('odpri'));
      await tester.pumpAndSettle();
      expect(find.text('Vroča točka · še brez zapisov'), findsOneWidget);
    });

    testWidgets('Foto and Šifrant hand back the speed dial\'s two entries',
        (tester) async {
      final state = await _bootOffline([_hotspot]);
      for (final (label, entry) in [
        ('Foto', HotspotEntry.photo),
        ('Šifrant', HotspotEntry.codebook),
      ]) {
        final result = await pumpSheet(tester, state);
        await tester.tap(find.text('odpri'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(result(), entry, reason: label);
      }
    });
  });
}
