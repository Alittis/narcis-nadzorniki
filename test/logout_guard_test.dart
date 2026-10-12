// TB-45: logging out must not silently discard work the server never received.
//
// `AppState.logout()` wipes both local stores — deliberately, so the next user
// of the device does not see the previous user's records. Until TB-45 that
// included rows still queued for the server, with no warning: a record captured
// offline was gone the moment its author logged out. These tests pin the guard
// in front of it: send what can be sent, and ask before discarding the rest.
//
// The harness is a trimmed copy of record_delete_test.dart's booted AppState,
// with seedable walks. `logout()` itself is never called here — it reaches the
// foreground-service and secure-storage plugins — so the widget tests hand
// LogoutTile a recording callback instead.

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
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/logout_tile.dart';
import 'package:provider/provider.dart';

Disturbance _rec(
  String id, {
  bool pendingSync = false,
  bool pendingDelete = false,
  bool photoPending = false,
}) {
  return Disturbance(
    id: id,
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: DateTime.utc(2026, 9, 1, 9),
    types: const [],
    description: 'opis',
    photos: [
      if (photoPending)
        DisturbancePhoto(
          id: '$id-foto',
          mimeType: 'image/jpeg',
          localPath: null,
          pendingUpload: true,
        ),
    ],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: 'Odprto',
    pendingSync: pendingSync,
    pendingDelete: pendingDelete,
    createdAt: DateTime.utc(2026, 9, 1, 9),
    createdBy: 'warden@gov.si',
  );
}

Map<String, dynamic> _remoteJson(String id) => {
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

Walk _walk(String id, {bool pendingSync = true}) => Walk(
      id: id,
      startedAt: DateTime.utc(2026, 9, 1, 8),
      endedAt: DateTime.utc(2026, 9, 1, 9),
      pendingSync: pendingSync,
      createdBy: 'warden@gov.si',
    );

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

class _Harness {
  _Harness({
    required this.online,
    required List<Disturbance> records,
    List<Walk> walks = const [],
  })  : store = _FakeStore(records),
        walksStore = _FakeWalksStore(walks);

  final bool online;
  final _FakeStore store;
  final _FakeWalksStore walksStore;
  final requests = <String>[];
  final accepted = <String>[];

  /// What the server answers a create with. Starts at 500 so boot's own
  /// syncAll leaves the queue in place; a test flips it to let a send land.
  int postStatus = 500;
  late final AppState state;

  /// UTF-8 explicitly: see record_delete_test.dart — a latin-1 default makes
  /// the pull throw on `Natančna` and be swallowed, silently.
  static http.Response _json(Object body, int status) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<void> boot() async {
    final client = MockClient((req) async {
      requests.add('${req.method} ${req.url.path}');
      if (req.method == 'GET') {
        return req.url.path.contains('/walks')
            ? _json({'walks': <dynamic>[]}, 200)
            : _json({'records': [for (final id in accepted) _remoteJson(id)]},
                200);
      }
      if (req.method == 'POST') {
        // A real server lists what it accepted on the next pull; one that
        // did not would make the merge evict the record, as it should.
        if (postStatus == 201) {
          accepted.add((jsonDecode(req.body) as Map)['id'] as String);
        }
        return http.Response('', postStatus);
      }
      return http.Response('', 200);
    });
    state = AppState(
      localStore: store,
      walksStore: walksStore,
      remoteApi: RemoteApi(client: client),
      connectivity: _FakeConnectivity(online),
      authService: _FakeAuth(),
      legacyLoader: _FakeLegacy(),
      photoStorage: PhotoStorage(),
    );
    await state.init();
    // pumpEventQueue() hangs inside testWidgets, so only the plain tests boot
    // online (record_delete_test.dart has the long version of this note).
    if (online) await pumpEventQueue();
  }
}

void main() {
  group('unsentWork', () {
    test('counts each kind, and agrees with the sync badge', () async {
      final h = _Harness(
        online: false,
        records: [
          _rec('r1', pendingSync: true),
          _rec('r2', photoPending: true),
          _rec('r3', pendingDelete: true),
          _rec('r4'), // synced: nothing at stake
        ],
        walks: [_walk('w1'), _walk('w2', pendingSync: false)],
      );
      await h.boot();

      final unsent = h.state.unsentWork;

      expect(unsent.records, 2, reason: 'the queued create and the photo');
      expect(unsent.deletes, 1);
      expect(unsent.walks, 1);
      expect(unsent.activeWalk, isFalse);
      expect(unsent.isEmpty, isFalse);
      // Same work the Profil card and the sync icon already show, so the
      // dialog can never disagree with the number the user has been looking at.
      expect(unsent.records + unsent.deletes + unsent.walks,
          h.state.pendingPushCount);
    });

    test('nothing pending reads as empty', () async {
      final h = _Harness(online: false, records: [_rec('r1')]);
      await h.boot();
      expect(h.state.unsentWork.isEmpty, isTrue);
    });
  });

  group('sendUnsentBeforeLogout', () {
    test('online: sends the queue first, so nothing is left to lose',
        () async {
      final h = _Harness(online: true, records: [_rec('r1', pendingSync: true)]);
      await h.boot();
      expect(h.state.unsentWork.records, 1, reason: 'boot could not send it');

      h.postStatus = 201;
      final left = await h.state.sendUnsentBeforeLogout();

      expect(left.isEmpty, isTrue);
      expect(h.store.seed.single.pendingSync, isFalse);
    });

    test('online but the server refuses: reports what is still at stake',
        () async {
      final h = _Harness(online: true, records: [_rec('r1', pendingSync: true)]);
      await h.boot();

      final left = await h.state.sendUnsentBeforeLogout();

      expect(left.records, 1);
    });

    test('offline: no request, and the queue is reported as is', () async {
      final h = _Harness(online: false, records: [_rec('r1', pendingSync: true)]);
      await h.boot();

      final left = await h.state.sendUnsentBeforeLogout();

      expect(left.records, 1);
      expect(h.requests, isEmpty);
    });
  });

  group('LogoutTile', () {
    Future<List<String>> pumpTile(WidgetTester tester, _Harness h) async {
      final calls = <String>[];
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: h.state,
          child: MaterialApp(
            home: Scaffold(
              body: LogoutTile(
                email: 'warden@gov.si',
                onLogout: () async => calls.add('logout'),
              ),
            ),
          ),
        ),
      );
      return calls;
    }

    testWidgets('nothing at stake: logs out straight away, no dialog',
        (tester) async {
      final h = _Harness(online: false, records: [_rec('r1')]);
      await h.boot();
      final calls = await pumpTile(tester, h);

      await tester.tap(find.text('Odjava'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, ['logout']);
    });

    testWidgets('unsent work: says what, and Prekliči keeps it',
        (tester) async {
      final h = _Harness(
        online: false,
        records: [_rec('r1', pendingSync: true)],
        walks: [_walk('w1')],
      );
      await h.boot();
      final calls = await pumpTile(tester, h);

      await tester.tap(find.text('Odjava'));
      await tester.pumpAndSettle();

      expect(find.text('Neposlani podatki'), findsOneWidget);
      expect(find.text('• zapisi: 1'), findsOneWidget);
      expect(find.text('• obhodi: 1'), findsOneWidget);
      expect(find.textContaining('izbrisi'), findsNothing,
          reason: 'only kinds that are actually pending are listed');

      await tester.tap(find.text('Prekliči'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: 'the queue must survive a cancel');
      expect(h.store.seed.single.pendingSync, isTrue);
    });

    testWidgets('a tap outside the dialog also keeps it', (tester) async {
      final h = _Harness(online: false, records: [_rec('r1', pendingSync: true)]);
      await h.boot();
      final calls = await pumpTile(tester, h);

      await tester.tap(find.text('Odjava'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5)); // the barrier
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isEmpty);
    });

    testWidgets('Odjavi in zavrzi goes ahead — the user chose it',
        (tester) async {
      final h = _Harness(online: false, records: [_rec('r1', pendingSync: true)]);
      await h.boot();
      final calls = await pumpTile(tester, h);

      await tester.tap(find.text('Odjava'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odjavi in zavrzi'));
      await tester.pumpAndSettle();

      expect(calls, ['logout']);
    });
  });

  group('the dialog', () {
    testWidgets('names a walk still being recorded', (tester) async {
      // An active walk cannot be booted here (init would restart the
      // foreground service), so the dialog is driven directly.
      late Future<bool> result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showUnsentWorkDialog(
              context,
              const UnsentWork(
                  records: 0, deletes: 0, walks: 0, activeWalk: true),
            ),
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('• obhod, ki se še snema'), findsOneWidget);
      expect(find.text('Obhod pred odjavo zaključite.'), findsOneWidget);
      expect(find.textContaining('zapisi'), findsNothing);

      await tester.tap(find.text('Prekliči'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('fits a 320 dp screen at a large text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.6),
          ),
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUnsentWorkDialog(
                context,
                const UnsentWork(
                    records: 12, deletes: 3, walks: 2, activeWalk: true),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'no overflow');
      expect(find.text('Odjavi in zavrzi'), findsOneWidget);
    });
  });
}
