// TB-8: pause and resume a walk without ending it.
//
// A pause stops the recording service (and its GPS stream) but keeps the walk
// open in active_walk.json with every point it has. These tests run the real
// AppState against a faked foreground-service channel and an in-memory walk
// store standing in for that file, which the service's isolate also writes.

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

const _fgs = MethodChannel('flutter_foreground_task/methods');

WalkPoint _pt(int seq) => WalkPoint(
      seq: seq,
      latitude: 45.79 + seq * 0.0001,
      longitude: 14.36,
      timestamp: DateTime.utc(2026, 10, 12, 9, seq),
      accuracy: 5,
    );

Walk _active({DateTime? pausedAt, int points = 3}) => Walk(
      id: 'w1',
      startedAt: DateTime.utc(2026, 10, 12, 9),
      endedAt: DateTime.utc(2026, 10, 12, 9, points),
      pendingSync: true,
      createdBy: 'warden@gov.si',
      points: [for (var i = 0; i < points; i++) _pt(i)],
      pausedAt: pausedAt,
    );

class _FakeStore extends LocalStore {
  @override
  Future<List<Disturbance>> load() async => [];
  @override
  Future<void> save(List<Disturbance> items) async {}
}

/// `active` plays active_walk.json: AppState and the service isolate both
/// read and write it.
class _MemWalksStore extends WalksLocalStore {
  _MemWalksStore([this.active]);
  Walk? active;
  List<Walk> saved = [];
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

class _FakeLegacy extends LegacyRecordsLoader {
  @override
  Future<List<LegacyDisturbance>> load() async => const [];
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

/// The recording service as the plugin channel reports it.
bool _running = false;
final _fgsCalls = <String>[];

/// Bodies of walk POSTs, as sent.
final _walkPosts = <Map<String, dynamic>>[];

Future<AppState> _boot(_MemWalksStore walks, {bool online = false}) async {
  final client = MockClient((req) async {
    if (req.method == 'POST' && req.url.path.contains('/walks')) {
      _walkPosts.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('', 201);
    }
    final body = req.url.path.contains('/walks')
        ? {'walks': <dynamic>[]}
        : {'records': <dynamic>[]};
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final state = AppState(
    localStore: _FakeStore(),
    walksStore: walks,
    remoteApi: RemoteApi(client: client),
    connectivity: _Connectivity(online),
    authService: _FakeAuth(),
    legacyLoader: _FakeLegacy(),
  );
  await state.init();
  await pumpEventQueue();
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // main.dart does this at boot; startService refuses to run without it.
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
    _running = false;
    _fgsCalls.clear();
    _walkPosts.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fgs, (call) async {
      _fgsCalls.add(call.method);
      switch (call.method) {
        case 'isRunningService':
          return _running;
        case 'startService':
          _running = true;
          return true;
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

  test('pausing stops the service and keeps the walk open, every point '
      'included', () async {
    final walks = _MemWalksStore();
    final state = await _boot(walks);
    await state.startWalk();
    expect(_running, isTrue);
    // The service isolate recorded three fixes into the file; none reached
    // the UI mirror over the port.
    walks.active = walks.active!.copyWith(
      points: [_pt(0), _pt(1), _pt(2)],
    );
    expect(state.activePoints, isEmpty);

    await state.pauseWalk();

    expect(_running, isFalse);
    expect(_fgsCalls, contains('stopService'));
    expect(state.hasActiveWalk, isTrue);
    expect(state.isWalkPaused, isTrue);
    expect(state.activePoints, hasLength(3));
    expect(walks.active!.pausedAt, isNotNull, reason: 'survives an app kill');
    expect(walks.active!.points, hasLength(3));
  });

  test('resuming restarts the service on the same walk', () async {
    final walks = _MemWalksStore(_active(pausedAt: DateTime.utc(2026, 10, 12, 10)));
    final state = await _boot(walks);
    expect(_fgsCalls, isNot(contains('startService')));

    await state.resumeWalk();

    expect(_running, isTrue);
    expect(state.isWalkPaused, isFalse);
    // The handler reads this file on start: it must see the walk unpaused,
    // same id, points intact.
    expect(walks.active!.pausedAt, isNull);
    expect(walks.active!.id, 'w1');
    expect(walks.active!.points, hasLength(3));
  });

  test('a paused walk stays paused across an app restart', () async {
    final walks = _MemWalksStore(_active(pausedAt: DateTime.utc(2026, 10, 12, 10)));
    final state = await _boot(walks);

    expect(state.hasActiveWalk, isTrue);
    expect(state.isWalkPaused, isTrue);
    expect(_fgsCalls, isNot(contains('startService')));
    expect(_running, isFalse);
  });

  test('a recording walk is still restarted after an app kill', () async {
    // The control for the test above: same harness, no pause.
    final walks = _MemWalksStore(_active());
    final state = await _boot(walks);

    expect(state.isWalkPaused, isFalse);
    expect(_fgsCalls, contains('startService'));
  });

  test('a walk ended while paused ends at the pause, and the pause is not '
      'sent', () async {
    final pausedAt = DateTime.utc(2026, 10, 12, 10, 30);
    final walks = _MemWalksStore(_active(pausedAt: pausedAt));
    final state = await _boot(walks, online: true);

    final completed = await state.endWalk(name: 'Cerkniško jezero');

    expect(completed!.endedAt, pausedAt);
    expect(completed.pausedAt, isNull);
    expect(completed.points, hasLength(3));
    expect(walks.active, isNull);
    expect(state.hasActiveWalk, isFalse);

    expect(_walkPosts, hasLength(1));
    final body = _walkPosts.single;
    expect(body['endedAt'], pausedAt.toIso8601String());
    expect(body.containsKey('pausedAt'), isFalse);
    expect(body['points'], hasLength(3));
  });

  test('pausedAt survives the local file round trip', () {
    final pausedAt = DateTime.utc(2026, 10, 12, 10, 30);
    final walk = _active(pausedAt: pausedAt);

    expect(Walk.fromJson(walk.toJson()).pausedAt, pausedAt);
    expect(Walk.fromJson(_active().toJson()).pausedAt, isNull);
    expect(walk.copyWith(clearPausedAt: true).pausedAt, isNull);
    expect(walk.copyWith(name: 'x').pausedAt, pausedAt);
  });
}
