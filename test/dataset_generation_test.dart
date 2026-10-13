// TB-46 (narcis-vibed NV-259 D6): the dataset-generation guard, and the
// minimum-build answer, on the real AppState against a stateful fake server.
//
// A pull evicts every synced local record the server does not list (the
// cross-account-bleed fix). So when the server's data set is REPLACED — the
// cutover from Oracle, or a restore from a backup that lost the last hours —
// an ordinary pull would delete the phones' own copies of exactly the records
// the server lost. The server mints a new generation on every replacement and
// sends it as X-Beleznica-Generation; on a generation it has not merged yet,
// the phone re-queues its own unlisted records, photos and walks instead, and
// the idempotent POSTs put them back. These tests pin that, and pin the
// ordinary behaviour around it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/dataset_generation_store.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/update_required_screen.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

const _me = 'ana@gov.si';
const _mate = 'bor@gov.si';
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

DisturbancePhoto _photo(String id, String? path) => DisturbancePhoto(
      id: id,
      mimeType: 'image/jpeg',
      localPath: path,
      pendingUpload: false,
    );

Disturbance _rec(
  String id, {
  String author = _me,
  List<DisturbancePhoto> photos = const [],
  bool pendingSync = false,
  bool pendingDelete = false,
  String? obhodId,
}) =>
    Disturbance(
      id: id,
      latitude: 45.79,
      longitude: 14.36,
      locationAccuracy: 'Natančna',
      observedAt: DateTime.utc(2026, 10, 13, 9),
      types: const [],
      description: 'opis',
      photos: photos,
      observers: const [],
      actionTaken: 'Opozorilo',
      caseStatus: 'Odprto',
      pendingSync: pendingSync,
      pendingDelete: pendingDelete,
      createdAt: DateTime.utc(2026, 10, 13, 9),
      createdBy: author,
      obhodId: obhodId,
    );

Walk _walk(String id, {String author = _me}) => Walk(
      id: id,
      startedAt: DateTime.utc(2026, 10, 13, 8),
      endedAt: DateTime.utc(2026, 10, 13, 9),
      pendingSync: false,
      createdBy: author,
      points: [
        WalkPoint(seq: 0, latitude: 45.79, longitude: 14.36, timestamp: DateTime.utc(2026, 10, 13, 8)),
        WalkPoint(seq: 1, latitude: 45.8, longitude: 14.37, timestamp: DateTime.utc(2026, 10, 13, 9)),
      ],
      pointCount: 2,
    );

/// The field-app API as far as the sync engine sees it: skip-if-exists
/// POSTs, org lists, the generation header. Holds its own state, so a
/// "restore" is removing rows and changing [generation].
class _Server {
  _Server(this.generation);

  String? generation;
  final records = <String, Map<String, dynamic>>{};
  final photos = <String, List<String>>{};
  final walks = <String, Map<String, dynamic>>{};
  final points = <String, List<dynamic>>{};
  bool failRecordsList = false;
  int? answerEverything;
  final log = <String>[];

  void holds(Disturbance d, {List<String> photoIds = const []}) {
    records[d.id] = {
      'id': d.id,
      'latitude': d.latitude,
      'longitude': d.longitude,
      'locationAccuracy': d.locationAccuracy,
      'observedAt': d.observedAt.toUtc().toIso8601String(),
      'createdAt': d.createdAt.toUtc().toIso8601String(),
      'createdBy': d.createdBy,
      'description': d.description,
      'actionTaken': d.actionTaken,
      'caseStatus': d.caseStatus,
      'obhodId': ?d.obhodId,
      'types': <dynamic>[],
      'observers': <dynamic>[],
    };
    photos[d.id] = [...photoIds];
  }

  void holdsWalk(Walk w) {
    walks[w.id] = {
      'id': w.id,
      'startedAt': w.startedAt.toUtc().toIso8601String(),
      'endedAt': w.endedAt.toUtc().toIso8601String(),
      'createdAt': w.startedAt.toUtc().toIso8601String(),
      'createdBy': w.createdBy,
      'pointCount': w.points.length,
      'disturbanceCount': 0,
    };
    points[w.id] = [for (final p in w.points) p.toJson()];
  }

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-beleznica-generation': ?generation,
      };

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _headers);

  Future<http.Response> handle(http.Request req) async {
    final p = req.url.pathSegments.sublist(4); // after api/beleznica/app/v1
    log.add('${req.method} /${p.join('/')}');
    if (answerEverything != null) {
      return http.Response('{"error":"update_required","minBuild":99}',
          answerEverything!, headers: {'content-type': 'application/json'});
    }
    switch ((req.method, p)) {
      case ('GET', ['disturbances']):
        if (failRecordsList) return http.Response('{"error":"x"}', 500);
        return _json({
          'records': [
            for (final r in records.values)
              {
                ...r,
                'photos': [
                  for (final id in photos[r['id']]!)
                    {'id': id, 'mimeType': 'image/jpeg'},
                ],
              },
          ],
        });
      case ('POST', ['disturbances']):
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        final id = b['id'] as String;
        if (records.containsKey(id)) {
          return _json({'id': id, 'status': 'exists'});
        }
        records[id] = {
          ...b..removeWhere((_, v) => v == null),
          'createdAt': b['observedAt'],
          'createdBy': _me,
        };
        photos[id] = [];
        return _json({'id': id, 'status': 'created'}, 201);
      case ('DELETE', ['disturbances', final id]):
        if (records.remove(id) == null) return _json({'error': 'not_found'}, 404);
        return http.Response('', 204);
      case ('POST', ['disturbances', final id, 'photos', final photoId]):
        if (!records.containsKey(id)) return _json({'error': 'not_found'}, 404);
        if (photos[id]!.contains(photoId)) return _json({'status': 'exists'});
        photos[id]!.add(photoId);
        return _json({'status': 'created'}, 201);
      case ('GET', ['walks']):
        return _json({'walks': walks.values.toList()});
      case ('POST', ['walks']):
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        final id = b['id'] as String;
        if (walks.containsKey(id)) return _json({'id': id, 'status': 'exists'});
        final pts = b['points'] as List<dynamic>;
        walks[id] = {
          'id': id,
          'startedAt': b['startedAt'],
          'endedAt': b['endedAt'],
          'createdAt': b['startedAt'],
          'createdBy': _me,
          'pointCount': pts.length,
          'disturbanceCount': 0,
        };
        points[id] = pts;
        return _json({'id': id, 'status': 'created'}, 201);
      case ('GET', ['walks', final id, 'points']):
        return _json({'obhodId': id, 'points': points[id] ?? <dynamic>[]});
    }
    return _json({'error': 'not_found'}, 404);
  }
}

class _FakeStore extends LocalStore {
  _FakeStore(this.seed);
  List<Disturbance> seed;
  @override
  Future<List<Disturbance>> load() async => seed;
  @override
  Future<void> save(List<Disturbance> items) async => seed = items;
}

class _FakeWalksStore extends WalksLocalStore {
  _FakeWalksStore(this.seed);
  List<Walk> seed;
  @override
  Future<List<Walk>> load() async => seed;
  @override
  Future<Walk?> loadActive() async => null;
  @override
  Future<void> save(List<Walk> walks) async => seed = walks;
  @override
  Future<void> clearActive() async {}
}

class _FakeGenerationStore extends DatasetGenerationStore {
  _FakeGenerationStore(this.value);
  String? value;
  @override
  Future<String?> load() async => value;
  @override
  Future<void> save(String generation) async => value = generation;
}

class _FakeAuth extends AuthService {
  StoredSession? stored = const StoredSession(email: _me, token: 'tok-ana');
  @override
  Future<StoredSession?> readStoredSession() async => stored;
  @override
  Future<void> revokeToken(String token) async {}
  @override
  Future<void> clearCache() async => stored = null;
}

class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

class _Phone {
  _Phone(this.server, {required List<Disturbance> records, List<Walk> walks = const [], String? known, required this.photoRoot})
      : store = _FakeStore(records),
        walksStore = _FakeWalksStore(walks),
        generations = _FakeGenerationStore(known);

  final _Server server;
  final _FakeStore store;
  final _FakeWalksStore walksStore;
  final _FakeGenerationStore generations;
  final auth = _FakeAuth();
  final Directory photoRoot;
  late final AppState state;

  Future<void> boot() async {
    state = AppState(
      localStore: store,
      walksStore: walksStore,
      remoteApi: RemoteApi(client: MockClient(server.handle)),
      connectivity: _Online(),
      authService: auth,
      photoStorage: PhotoStorage(rootResolver: () => photoRoot),
      generationStore: generations,
    );
    await state.init();
    await settle();
  }

  /// Until the follow-up pass a re-queue starts has finished too.
  Future<void> settle() async {
    for (var quiet = 0; quiet < 3;) {
      await pumpEventQueue();
      quiet = state.isSyncing ? 0 : quiet + 1;
    }
  }

  Disturbance? record(String id) {
    for (final r in store.seed) {
      if (r.id == id) return r;
    }
    return null;
  }

  Walk? walk(String id) {
    for (final w in walksStore.seed) {
      if (w.id == id) return w;
    }
    return null;
  }
  List<String> get posts => server.log.where((l) => l.startsWith('POST')).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory photoRoot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tb46_');
    photoRoot = Directory('${tmp.path}/disturbance_photos');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A photo file where PhotoStorage keeps it.
  String file(String motnjaId, String photoId) {
    final f = File('${photoRoot.path}/$motnjaId/$photoId.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_jpeg);
    return f.path;
  }

  test('a restore that lost own work: the new generation re-sends it, photos '
      'and walk included, and evicts only the teammate\'s', () async {
    // What the phone holds, all synced before the restore.
    final r1 = _rec('r1', photos: [_photo('p1', file('r1', 'p1'))]);
    final r2 = _rec('r2', photos: [_photo('p2', '${photoRoot.path}/r2/p2.jpg')]); // file gone
    final r3 = _rec('r3', photos: [_photo('p3', file('r3', 'p3'))]); // survives; its photo does not
    final r4 = _rec('r4', obhodId: 'w1');
    final t1 = _rec('t1', author: _mate);
    final w1 = _walk('w1');
    // The server after the restore: only r3 survived, without its photo.
    final server = _Server('gen-2')..holds(r3);
    final phone = _Phone(server,
        records: [r1, r2, r3, r4, t1], walks: [w1], known: 'gen-1', photoRoot: photoRoot);
    await phone.boot();

    expect(phone.posts, containsAllInOrder(['POST /walks', 'POST /disturbances']),
        reason: 'the walk goes first: r4 links to it');
    expect(server.walks.keys, contains('w1'));
    expect(server.points['w1'], hasLength(2), reason: 'with its points');
    expect(server.records.keys, containsAll(['r1', 'r2', 'r3', 'r4']));
    expect(server.records['r4']!['obhodId'], 'w1');
    expect(server.photos['r1'], ['p1']);
    expect(server.photos['r3'], ['p3'], reason: 'the surviving record\'s lost photo (owner, 2026-10-13)');
    expect(server.photos['r2'], isEmpty, reason: 'a photo whose file is gone cannot go back');
    expect(server.records.keys, isNot(contains('t1')), reason: 'only own work is re-sent');

    expect(phone.record('t1'), isNull, reason: 'a teammate\'s is evicted as always');
    for (final id in ['r1', 'r2', 'r3', 'r4']) {
      expect(phone.record(id)?.pendingSync, isFalse, reason: '$id back and synced');
    }
    expect(phone.record('r2')!.photos, isEmpty);
    expect(phone.walk('w1')?.pendingSync, isFalse);
    expect(phone.state.pendingPushCount, 0);
    expect(phone.generations.value, 'gen-2');
  });

  test('the same generation evicts as always', () async {
    final server = _Server('gen-2');
    final phone = _Phone(server, records: [_rec('r1')], walks: [_walk('w1')], known: 'gen-2', photoRoot: photoRoot);
    await phone.boot();
    expect(phone.record('r1'), isNull);
    expect(phone.walk('w1'), isNull);
    expect(phone.posts, isEmpty);
  });

  test('a list without a generation is merged as always, and nothing is stored',
      () async {
    final server = _Server(null);
    final phone = _Phone(server, records: [_rec('r1')], known: null, photoRoot: photoRoot);
    await phone.boot();
    expect(phone.record('r1'), isNull);
    expect(phone.posts, isEmpty);
    expect(phone.generations.value, isNull);
  });

  test('the cutover: the first pull of a complete copy evicts nothing and '
      're-sends nothing', () async {
    final r1 = _rec('r1');
    final t1 = _rec('t1', author: _mate);
    final w1 = _walk('w1');
    final server = _Server('gen-1')
      ..holds(r1)
      ..holds(t1)
      ..holdsWalk(w1);
    final phone = _Phone(server, records: [r1, t1], walks: [w1], known: null, photoRoot: photoRoot);
    await phone.boot();
    expect(phone.record('r1'), isNotNull);
    expect(phone.record('t1'), isNotNull);
    expect(phone.walk('w1'), isNotNull);
    expect(phone.posts, isEmpty);
    expect(phone.generations.value, 'gen-1');
  });

  test('the generation is stored only once BOTH lists merged under it', () async {
    final server = _Server('gen-2')..failRecordsList = true;
    final phone = _Phone(server, records: [_rec('r1')], known: 'gen-1', photoRoot: photoRoot);
    await phone.boot();
    // The walks list arrived under gen-2, the records list failed.
    expect(phone.generations.value, 'gen-1');
    expect(phone.record('r1')?.pendingSync, isFalse);

    server.failRecordsList = false;
    await phone.state.syncAll();
    await phone.settle();
    // Stored after the walks alone, this pull would have seen "no change" and
    // evicted r1.
    expect(server.records.keys, contains('r1'));
    expect(phone.record('r1')?.pendingSync, isFalse);
    expect(phone.generations.value, 'gen-2');
  });

  test('a delete waiting to go out is not re-queued', () async {
    final server = _Server('gen-2');
    final phone = _Phone(server, records: [_rec('r1', pendingDelete: true)], known: 'gen-1', photoRoot: photoRoot);
    await phone.boot();
    expect(server.log, contains('DELETE /disturbances/r1'));
    expect(phone.posts, isEmpty);
    expect(phone.record('r1'), isNull, reason: '404 counts as done');
  });

  group('the minimum build (426)', () {
    test('stops sync, keeps the session and the queue, asks for the update',
        () async {
      final server = _Server('gen-1')..answerEverything = 426;
      final queued = _rec('r1', pendingSync: true);
      final phone = _Phone(server, records: [queued, _rec('r2')], known: 'gen-1', photoRoot: photoRoot);
      await phone.boot();
      expect(phone.state.updateRequired, isTrue);
      expect(phone.state.canSync, isFalse);
      expect(phone.state.isAuthenticated, isTrue, reason: 'not a logout');
      expect(phone.auth.stored, isNotNull, reason: 'the token is kept');
      expect(phone.record('r1')?.pendingSync, isTrue, reason: 'the queue is kept');
      expect(phone.record('r2'), isNotNull, reason: 'no pull merged, nothing evicted');
      expect(server.log.where((l) => l.startsWith('POST')), hasLength(lessThanOrEqualTo(1)),
          reason: 'the sync stops at the first 426');
    });

    testWidgets('the screen says the work stays on the device', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: UpdateRequiredScreen()));
      expect(find.text(updateRequiredTitle), findsOneWidget);
      expect(find.textContaining('ostanejo na napravi'), findsOneWidget);
    });
  });
}
