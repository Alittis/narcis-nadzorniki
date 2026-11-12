// TB-55: a record captured during a walk that is then discarded must still be
// sendable.
//
// A record made while a walk is on carries the walk's id and is held back
// until the walk reaches the server. A discarded walk never does — *Zavrzi* in
// the end-walk sheet, or the automatic discard of a walk with no points — so a
// record still pointing at it failed the walk FK on every POST, for ever. The
// mock server here refuses a record whose walk it has not received, as the real
// one does (`motnja_obhod_id_fkey`).

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

const _fgs = MethodChannel('flutter_foreground_task/methods');

WalkPoint _pt(int seq) => WalkPoint(
      seq: seq,
      latitude: 45.79 + seq * 0.0001,
      longitude: 14.36,
      timestamp: DateTime.utc(2026, 11, 12, 9, seq),
      accuracy: 5,
    );

Walk _walk(String id, {int points = 0, bool pendingSync = true}) => Walk(
      id: id,
      startedAt: DateTime.utc(2026, 11, 12, 9),
      endedAt: DateTime.utc(2026, 11, 12, 10),
      pendingSync: pendingSync,
      createdBy: 'warden@gov.si',
      points: [for (var i = 0; i < points; i++) _pt(i)],
    );

Disturbance _record(String id, {String? obhodId}) => Disturbance(
      id: id,
      latitude: 45.79,
      longitude: 14.36,
      locationAccuracy: 'Natančna',
      observedAt: DateTime.utc(2026, 11, 12, 9, 15),
      types: const [],
      description: 'opis',
      photos: const [],
      observers: const [],
      actionTaken: 'Brez ukrepa',
      caseStatus: 'Odprto',
      pendingSync: true,
      createdAt: DateTime.utc(2026, 11, 12, 9, 15),
      obhodId: obhodId,
    );

class _MemStore extends LocalStore {
  _MemStore([List<Disturbance>? initial]) : saved = initial ?? [];
  List<Disturbance> saved;
  @override
  Future<List<Disturbance>> load() async => saved;
  @override
  Future<void> save(List<Disturbance> items) async => saved = items;
}

class _MemWalksStore extends WalksLocalStore {
  _MemWalksStore({this.active, List<Walk>? walks}) : saved = walks ?? [];
  Walk? active;
  List<Walk> saved;
  @override
  Future<List<Walk>> load() async => saved;
  @override
  Future<void> save(List<Walk> walks) async => saved = walks;
  @override
  Future<Walk?> loadActive() async => active;
  @override
  Future<void> saveActive(Walk walk) async => active = walk;
  @override
  Future<void> clearActive() async => active = null;
}

class _FakeAuth extends AuthService {
  @override
  Future<StoredSession?> readStoredSession() async =>
      const StoredSession(email: 'warden@gov.si', token: 'tok');
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

bool _running = false;

/// The walks the mock server holds; a record naming any other walk is refused.
final _serverWalks = <String>{};

/// Record POST bodies the server accepted.
final _accepted = <Map<String, dynamic>>[];

/// Record POSTs refused on the walk FK.
var _fkRefusals = 0;

Future<AppState> _boot(
  _MemStore records,
  _MemWalksStore walks, {
  bool online = true,
}) async {
  final client = MockClient((req) async {
    final path = req.url.path;
    if (req.method == 'POST' && path.endsWith('/walks')) {
      _serverWalks.add((jsonDecode(req.body) as Map)['id'] as String);
      return http.Response('', 201);
    }
    if (req.method == 'POST' && path.endsWith('/disturbances')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final walk = body['obhodId'] as String?;
      if (walk != null && !_serverWalks.contains(walk)) {
        _fkRefusals++;
        return http.Response(
            '{"error":"insert violates motnja_obhod_id_fkey"}', 500);
      }
      _accepted.add(body);
      return http.Response('', 201);
    }
    final body = path.contains('/walks')
        ? {'walks': <dynamic>[]}
        : {'records': <dynamic>[]};
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final state = AppState(
    localStore: records,
    walksStore: walks,
    remoteApi: RemoteApi(client: client),
    connectivity: _Connectivity(online),
    authService: _FakeAuth(),
  );
  await state.init();
  await pumpEventQueue();
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'narcis_obhod',
        channelName: 'Beleženje obhoda',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(),
    );
  });

  setUp(() {
    _running = true;
    _serverWalks.clear();
    _accepted.clear();
    _fkRefusals = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fgs, (call) async {
      switch (call.method) {
        case 'isRunningService':
          return _running;
        case 'stopService':
          _running = false;
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fgs, null);
  });

  test('Zavrzi: the record captured during the walk is kept, unlinked and '
      'sent', () async {
    final records = _MemStore();
    final walks = _MemWalksStore(active: _walk('w1', points: 3));
    final state = await _boot(records, walks);

    await state.addRecord(_record('m1'));
    expect(state.records.single.obhodId, 'w1');
    expect(_accepted, isEmpty, reason: 'held back while its walk is on');

    await state.cancelWalk();

    expect(state.records, hasLength(1), reason: 'field data is never dropped');
    final r = state.records.single;
    expect(r.obhodId, isNull);
    expect(r.pendingSync, isFalse);
    expect(records.saved.single.obhodId, isNull, reason: 'persisted');
    expect(_accepted.single['id'], 'm1');
    expect(_accepted.single['obhodId'], isNull);
    expect(_fkRefusals, 0);
  });

  test('a walk discarded for having no points: the same', () async {
    final records = _MemStore();
    final walks = _MemWalksStore(active: _walk('w1'));
    final state = await _boot(records, walks);
    await state.addRecord(_record('m1'));

    final saved = await state.endWalk(name: 'x');

    expect(saved, isNull, reason: 'the walk itself is discarded');
    expect(walks.saved, isEmpty);
    expect(state.records.single.obhodId, isNull);
    expect(state.records.single.pendingSync, isFalse);
    expect(_accepted.single['obhodId'], isNull);
    expect(_fkRefusals, 0);
  });

  test('offline: unlinked at once, and the next sync sends it', () async {
    final records = _MemStore();
    final walks = _MemWalksStore(active: _walk('w1', points: 3));
    final state = await _boot(records, walks, online: false);
    await state.addRecord(_record('m1'));

    await state.cancelWalk();

    expect(state.records.single.obhodId, isNull);
    expect(state.records.single.pendingSync, isTrue);
    expect(records.saved.single.obhodId, isNull);
    expect(_accepted, isEmpty);

    // Back online after a restart: the boot-time sync drains the queue with
    // no FK refusal.
    await _boot(records, walks);
    expect(_accepted.single['id'], 'm1');
    expect(_accepted.single['obhodId'], isNull);
    expect(_fkRefusals, 0);
  });

  test('records of other walks keep their link', () async {
    // m0 belongs to a walk saved earlier and still queued; only the
    // discarded walk's records lose theirs.
    final records = _MemStore([_record('m0', obhodId: 'w0')]);
    final walks = _MemWalksStore(
      active: _walk('w1', points: 3),
      walks: [_walk('w0', points: 3)],
    );
    final state = await _boot(records, walks, online: false);
    await state.addRecord(_record('m1'));

    await state.cancelWalk();

    final byId = {for (final r in state.records) r.id: r};
    expect(byId['m0']!.obhodId, 'w0');
    expect(byId['m1']!.obhodId, isNull);
  });

  test('a saved walk still links its records (the control)', () async {
    final records = _MemStore();
    final walks = _MemWalksStore(active: _walk('w1', points: 3));
    final state = await _boot(records, walks);
    await state.addRecord(_record('m1'));

    await state.endWalk(name: 'Cerkniško jezero');

    expect(state.records.single.obhodId, 'w1');
    expect(_accepted.single['obhodId'], 'w1');
    expect(_fkRefusals, 0);
  });

  test('copyWith(clearObhodId) clears; a plain copyWith keeps it', () {
    final r = _record('m1', obhodId: 'w1');
    expect(r.copyWith(clearObhodId: true).obhodId, isNull);
    expect(r.copyWith(description: 'x').obhodId, 'w1');
  });
}
