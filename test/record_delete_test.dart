// TB-2: deleting a record from the phone.
//
// The delete itself is one HTTP call. What these tests protect is the queue
// around it, because the naive version was actively harmful: it removed the row
// locally and fired DELETE without a retry, so an offline delete LOOKED like it
// worked and then undid itself on the next pull — `_mergeRemoteIntoLocal` treats
// the server as authoritative, found a row the server still had and no local
// copy, and re-created it. In an app used on weak signal that is data the
// warden believed they had removed, coming back.
//
// The load-bearing test is "a queued delete survives a failed attempt and the
// pull that follows it". Everything else supports that one.

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

const _id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

Disturbance _rec({
  String id = _id,
  bool pendingSync = false,
  String caseStatus = 'Odprto',
  String? reviewedBy,
  DateTime? reviewedAt,
}) {
  return Disturbance(
    id: id,
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: DateTime.utc(2026, 9, 1, 9),
    types: const [],
    description: 'opis',
    photos: const <DisturbancePhoto>[],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: caseStatus,
    pendingSync: pendingSync,
    createdAt: DateTime.utc(2026, 9, 1, 9),
    createdBy: 'warden@gov.si',
    reviewedBy: reviewedBy,
    reviewedAt: reviewedAt,
  );
}

/// What the server's GET list says about that same record.
Map<String, dynamic> _remoteJson({String id = _id}) => {
      'id': id,
      'latitude': 45.79,
      'longitude': 14.36,
      'locationAccuracy': 'Natančna',
      'observedAt': '2026-09-01T09:00:00.000Z',
      'types': <dynamic>[],
      'description': 'opis',
      'observers': <dynamic>[],
      'actionTaken': 'Brez ukrepa',
      'caseStatus': 'Odprto',
      'createdAt': '2026-09-01T09:00:00.000Z',
      'createdBy': 'warden@gov.si',
      'photos': <dynamic>[],
    };

class _FakeStore extends LocalStore {
  _FakeStore(this.seed);
  List<Disturbance> seed;

  @override
  Future<List<Disturbance>> load() async => seed;

  @override
  Future<void> save(List<Disturbance> items) async => seed = items;
}

class _FakeWalksStore extends WalksLocalStore {
  @override
  Future<List<Walk>> load() async => const [];
  @override
  Future<Walk?> loadActive() async => null;
  @override
  Future<void> save(List<Walk> walks) async {}
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

class _FakePhotos extends PhotoStorage {
  final deletedDirs = <String>[];
  @override
  Future<void> deleteRecordDir(String motnjaId) async =>
      deletedDirs.add(motnjaId);
}

/// `implements`, not `extends`: Connectivity's only public constructor is a
/// factory over a singleton. Its surface is these two members.
class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.online);
  final bool online;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [online ? ConnectivityResult.wifi : ConnectivityResult.none];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

/// A booted AppState on the real `init()` path: restored session, seeded local
/// store, a server that answers. `deleteStatus` is mutable so a test can make
/// the DELETE fail and then succeed.
class _Harness {
  _Harness({required this.online, List<Disturbance>? seed, bool serverHasIt = true})
      : store = _FakeStore(seed ?? [_rec()]),
        _serverHasIt = serverHasIt;

  final bool online;
  final _FakeStore store;
  final photos = _FakePhotos();
  final requests = <String>[];
  final bool _serverHasIt;
  int deleteStatus = 204;
  int postStatus = 201;
  late final AppState state;

  Future<void> boot() async {
    final client = MockClient((req) async {
      requests.add('${req.method} ${req.url.path}');
      if (req.url.path.contains('/walks')) {
        return http.Response(jsonEncode({'walks': <dynamic>[]}), 200);
      }
      if (req.method == 'DELETE') {
        return http.Response('', deleteStatus);
      }
      if (req.method == 'POST') {
        return http.Response('', postStatus);
      }
      if (req.method == 'GET') {
        // The server keeps reporting the record until a DELETE succeeds.
        final gone = requests.any((r) => r.startsWith('DELETE')) &&
            (deleteStatus == 204 || deleteStatus == 200);
        final rows = (_serverHasIt && !gone) ? [_remoteJson()] : <dynamic>[];
        return http.Response(jsonEncode({'records': rows}), 200);
      }
      return http.Response('', 200);
    });

    state = AppState(
      localStore: store,
      walksStore: _FakeWalksStore(),
      remoteApi: RemoteApi(client: client),
      connectivity: _FakeConnectivity(online),
      authService: _FakeAuth(),
      legacyLoader: _FakeLegacy(),
      photoStorage: photos,
    );
    await state.init();
    // Only when online: init() awaits its own syncAll, so nothing is left in
    // flight offline — and pumpEventQueue() HANGS inside testWidgets, where the
    // binding controls time and its timers fire only when the tester pumps.
    if (online) await pumpEventQueue();
  }
}

void main() {
  group('the model', () {
    test('pendingDelete round-trips, and is false on pre-TB-2 rows', () {
      final queued = _rec().copyWith(pendingDelete: true);
      expect(Disturbance.fromJson(queued.toJson()).pendingDelete, isTrue);

      final old = _rec().toJson()..remove('pendingDelete');
      expect(Disturbance.fromJson(old).pendingDelete, isFalse);
    });

    test('isLockedByReview follows the back office, not the warden', () {
      expect(_rec().isLockedByReview, isFalse);
      expect(_rec(reviewedBy: 'referent@gov.si').isLockedByReview, isTrue);
      expect(
        _rec(reviewedAt: DateTime.utc(2026, 9, 1)).isLockedByReview,
        isTrue,
      );
      expect(_rec(caseStatus: 'V obravnavi').isLockedByReview, isTrue);
      expect(_rec(caseStatus: 'Zaključeno').isLockedByReview, isTrue);
    });
  });

  group('offline', () {
    test('a delete is queued, hidden, persisted and counted', () async {
      final h = _Harness(online: false);
      await h.boot();
      expect(h.state.records, hasLength(1));

      final purged = await h.state.deleteRecord(_rec());

      expect(purged, isFalse, reason: 'nothing was confirmed by any server');
      expect(h.state.records, isEmpty, reason: 'the user sees it gone');
      expect(h.state.pendingPushCount, 1, reason: 'it is outstanding work');
      // Still on disk, so the queue survives a cold start.
      expect(h.store.seed.single.pendingDelete, isTrue);
      expect(h.photos.deletedDirs, isEmpty,
          reason: 'photos go only when the server confirms');
      expect(h.requests.where((r) => r.startsWith('DELETE')), isEmpty);
    });
  });

  group('online', () {
    test('a delete is sent, confirmed and purged', () async {
      final h = _Harness(online: true);
      await h.boot();

      final purged = await h.state.deleteRecord(_rec());

      expect(purged, isTrue);
      expect(h.state.records, isEmpty);
      expect(h.store.seed, isEmpty, reason: 'purged from disk too');
      expect(h.photos.deletedDirs, [_id]);
      expect(h.state.pendingPushCount, 0);
      expect(h.requests.where((r) => r.startsWith('DELETE')), hasLength(1));
    });

    test('a failed delete stays queued and the pull does NOT resurrect it',
        () async {
      final h = _Harness(online: true);
      await h.boot();
      h.deleteStatus = 500;

      final purged = await h.state.deleteRecord(_rec());
      expect(purged, isFalse);
      expect(h.state.records, isEmpty);

      // The whole point: a full sync, whose pull still lists the record from
      // the server, must not bring it back. Before the queue existed, this is
      // exactly where the delete undid itself.
      await h.state.syncAll();

      expect(h.state.records, isEmpty, reason: 'still gone for the user');
      expect(h.store.seed.single.pendingDelete, isTrue,
          reason: 'still queued, not overwritten by the server copy');
      expect(h.state.pendingPushCount, 1);

      // Server recovers: the next sync drains it for good.
      h.deleteStatus = 204;
      await h.state.syncAll();

      expect(h.store.seed, isEmpty);
      expect(h.photos.deletedDirs, [_id]);
      expect(h.state.pendingPushCount, 0);
    });

    test('a record queued for delete is never pushed as a create', () async {
      // Created offline and never sent, then deleted: POSTing it just to
      // DELETE it is two pointless round trips, and on a flaky link the POST
      // could land while the DELETE does not — leaving exactly the orphan the
      // user asked us to remove.
      final h = _Harness(
        online: true,
        seed: [_rec(pendingSync: true)],
        serverHasIt: false,
      );
      h.postStatus = 500; // boot's sync fails to push, so it stays pendingSync
      await h.boot();
      expect(h.store.seed.single.pendingSync, isTrue);

      h.requests.clear(); // ignore boot's own traffic
      await h.state.deleteRecord(_rec(pendingSync: true));
      await h.state.syncAll();

      expect(h.requests.where((r) => r.startsWith('POST')), isEmpty,
          reason: 'the create must be skipped, not sent then deleted');
      expect(h.state.records, isEmpty);
      expect(h.store.seed, isEmpty, reason: 'DELETE 404s and that counts');
    });
  });

  group('the row menu', () {
    Future<_Harness> open(WidgetTester tester, Disturbance record) async {
      final h = _Harness(online: false, seed: [record]);
      await h.boot();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: h.state,
          child: MaterialApp(
            home: Scaffold(
              body: Center(child: RecordActionsMenu(record: record)),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Izbriši zapis'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('a reviewed record explains itself instead of deleting',
        (tester) async {
      final h = await open(
        tester,
        _rec(caseStatus: 'Zaključeno', reviewedBy: 'referent@gov.si'),
      );

      // Enabled-and-explains, not greyed-out-and-silent: the warden learns why.
      expect(find.text('Zapisa ni mogoče izbrisati'), findsOneWidget);
      expect(find.textContaining('Zaključeno'), findsOneWidget);
      expect(find.text('Izbriši'), findsNothing, reason: 'no way through');
      expect(h.state.records, hasLength(1));
    });

    testWidgets('Prekliči leaves the record alone', (tester) async {
      final h = await open(tester, _rec());
      expect(find.text('Izbriši zapis?'), findsOneWidget);

      await tester.tap(find.text('Prekliči'));
      await tester.pumpAndSettle();

      expect(h.state.records, hasLength(1));
      expect(h.store.seed.single.pendingDelete, isFalse);
    });

    testWidgets('confirming queues the delete and says so', (tester) async {
      final h = await open(tester, _rec());

      await tester.tap(find.text('Izbriši'));
      await tester.pumpAndSettle();

      expect(h.state.records, isEmpty);
      expect(h.store.seed.single.pendingDelete, isTrue);
      // Offline, so the promise must be the honest one.
      expect(
        find.text('Zapis bo izbrisan ob naslednji sinhronizaciji.'),
        findsOneWidget,
      );
    });
  });
}
