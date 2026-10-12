// TB-48: a login must not send another account's unsent work as its own.
//
// A sync 401 drops the token but keeps the queue, so the next cold start lands
// on the login screen with the previous user's records still on the device.
// The server files a POST under whoever's token carries it, so if a different
// person logged in there, their first sync filed the old queue under their own
// name. These tests pin the guard: the queue names its own owner, a different
// account is asked first, and nothing is sent until it has answered.

import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:narcis_nadzorniki/screens/login_screen.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

const _ana = 'ana@gov.si';
const _bor = 'bor@gov.si';

Disturbance _rec(String id, {required bool pendingSync}) => Disturbance(
      id: id,
      latitude: 45.79,
      longitude: 14.36,
      locationAccuracy: 'Natančna',
      observedAt: DateTime.utc(2026, 9, 1, 9),
      types: const [],
      description: 'opis',
      photos: const [],
      observers: const [],
      actionTaken: 'Brez ukrepa',
      caseStatus: 'Odprto',
      pendingSync: pendingSync,
      createdAt: DateTime.utc(2026, 9, 1, 9),
      createdBy: _ana,
    );

Walk _walk(String id) => Walk(
      id: id,
      startedAt: DateTime.utc(2026, 9, 1, 8),
      endedAt: DateTime.utc(2026, 9, 1, 9),
      pendingSync: true,
      createdBy: _ana,
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
  @override
  Future<void> clearActive() async {}
}

/// Stands in for the server and secure storage. An online login succeeds for
/// anyone and, like the real one, stores the new session at once.
class _FakeAuth extends AuthService {
  _FakeAuth([this.stored]);
  StoredSession? stored;
  final revoked = <String>[];

  @override
  Future<AuthResult> login(
    String email,
    String password, {
    required bool online,
  }) async {
    final user = email.trim().toLowerCase();
    stored = StoredSession(email: user, token: 'tok-$user');
    return AuthResult(success: true, user: user, token: 'tok-$user');
  }

  @override
  Future<StoredSession?> readStoredSession() async => stored;

  @override
  Future<void> revokeToken(String token) async => revoked.add(token);

  @override
  Future<void> clearCache() async => stored = null;
}

class _FakeLegacy extends LegacyRecordsLoader {
  @override
  Future<List<LegacyDisturbance>> load() async => const [];
}

class _OnlineConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

class _Harness {
  _Harness({
    required List<Disturbance> records,
    List<Walk> walks = const [],
    StoredSession? stored,
    required this.photoRoot,
  })  : store = _FakeStore(records),
        walksStore = _FakeWalksStore(walks),
        auth = _FakeAuth(stored);

  final _FakeStore store;
  final _FakeWalksStore walksStore;
  final _FakeAuth auth;
  final Directory photoRoot;

  /// Each request as "METHOD path", with the token that carried it.
  final requests = <String>[];
  late final AppState state;

  List<String> get posts =>
      requests.where((r) => r.startsWith('POST')).toList();

  static http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<void> boot() async {
    final client = MockClient((req) async {
      requests.add('${req.method} ${req.url.path} '
          '${req.headers['X-Narcis-Auth'] ?? ''}');
      if (req.method == 'GET') {
        return req.url.path.contains('/walks')
            ? _json({'walks': <dynamic>[]})
            : _json({'records': <dynamic>[]});
      }
      return http.Response('', 201);
    });
    state = AppState(
      localStore: store,
      walksStore: walksStore,
      remoteApi: RemoteApi(client: client),
      connectivity: _OnlineConnectivity(),
      authService: auth,
      legacyLoader: _FakeLegacy(),
      photoStorage: PhotoStorage(rootResolver: () => photoRoot),
    );
    await state.init();
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory photoRoot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tb48_');
    photoRoot = Directory('${tmp.path}/disturbance_photos');
    // Discarding goes through the same wipe as logout(), which asks the
    // foreground-task plugin whether a walk is recording.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('login', () {
    test('the owner logging back in is not asked, and the queue is sent',
        () async {
      final h = _Harness(
        records: [_rec('m-unsent', pendingSync: true)],
        photoRoot: photoRoot,
      );
      await h.boot();
      expect(h.state.isAuthenticated, isFalse, reason: 'cold start after 401');

      var asked = false;
      final result = await h.state.login(
        ' Ana@gov.si ',
        'geslo',
        confirmDiscard: (_, _) async => asked = true,
      );
      await pumpEventQueue();

      expect(result.success, isTrue);
      expect(asked, isFalse);
      expect(h.posts, hasLength(1));
      expect(h.posts.single, contains('Bearer tok-$_ana'));
    });

    test('another account is asked first; Prekliči keeps the queue and '
        'refuses the login', () async {
      final h = _Harness(
        records: [_rec('m-unsent', pendingSync: true)],
        walks: [_walk('w-unsent')],
        photoRoot: photoRoot,
      );
      await h.boot();

      String? askedOwner;
      UnsentWork? askedUnsent;
      final result = await h.state.login(
        _bor,
        'geslo',
        confirmDiscard: (owner, unsent) async {
          askedOwner = owner;
          askedUnsent = unsent;
          return false;
        },
      );
      await pumpEventQueue();

      expect(askedOwner, _ana);
      expect(askedUnsent!.records, 1);
      expect(askedUnsent!.walks, 1);

      expect(result.success, isFalse);
      expect(result.message, contains(_ana));
      expect(h.state.isAuthenticated, isFalse);
      expect(h.posts, isEmpty, reason: 'nothing sent under bor\'s token');

      // Ana's work is untouched, so she can still log in and send it.
      expect(h.store.seed.single.pendingSync, isTrue);
      expect(h.walksStore.seed.single.pendingSync, isTrue);

      // Bor's session is undone: a cold start must not restore it over the
      // queue, and the token the login minted is revoked.
      expect(h.auth.stored, isNull);
      expect(h.auth.revoked, ['tok-$_bor']);
    });

    test('without a callback the login is refused, not let through', () async {
      final h = _Harness(
        records: [_rec('m-unsent', pendingSync: true)],
        photoRoot: photoRoot,
      );
      await h.boot();

      final result = await h.state.login(_bor, 'geslo');
      await pumpEventQueue();

      expect(result.success, isFalse);
      expect(h.posts, isEmpty);
      expect(h.store.seed, hasLength(1));
    });

    test('Zavrzi in nadaljuj empties the device, then logs in', () async {
      final photo = File('${photoRoot.path}/m-unsent/f1.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
      final h = _Harness(
        records: [
          _rec('m-unsent', pendingSync: true),
          _rec('m-synced', pendingSync: false),
        ],
        walks: [_walk('w-unsent')],
        photoRoot: photoRoot,
      );
      await h.boot();

      final result = await h.state.login(
        _bor,
        'geslo',
        confirmDiscard: (_, _) async => true,
      );
      await pumpEventQueue();

      expect(result.success, isTrue);
      expect(h.state.currentUser, _bor);
      expect(h.store.seed, isEmpty);
      expect(h.walksStore.seed, isEmpty);
      expect(photo.existsSync(), isFalse);
      expect(h.posts, isEmpty, reason: 'ana\'s record was discarded, not sent');
      expect(h.auth.revoked, isEmpty);
    });

    test('another account is not asked when nothing is unsent', () async {
      final h = _Harness(
        records: [_rec('m-synced', pendingSync: false)],
        photoRoot: photoRoot,
      );
      await h.boot();

      var asked = false;
      final result = await h.state.login(
        _bor,
        'geslo',
        confirmDiscard: (_, _) async => asked = true,
      );

      expect(result.success, isTrue);
      expect(asked, isFalse);
    });
  });

  test('a cold start does not restore a session over another account\'s '
      'queue', () async {
    // The app was killed while login() was asking: AuthService had already
    // stored bor's session.
    final h = _Harness(
      records: [_rec('m-unsent', pendingSync: true)],
      stored: const StoredSession(email: _bor, token: 'tok-$_bor'),
      photoRoot: photoRoot,
    );
    await h.boot();

    expect(h.state.isAuthenticated, isFalse);
    expect(h.posts, isEmpty);
    expect(h.auth.stored, isNull);
    expect(h.auth.revoked, ['tok-$_bor']);
    expect(h.store.seed.single.pendingSync, isTrue);
  });

  group('the dialog', () {
    Future<bool?> open(WidgetTester tester, String button) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async => answer = await showForeignUnsentDialog(
                context,
                owner: _ana,
                user: _bor,
                unsent: const UnsentWork(
                  records: 2,
                  deletes: 0,
                  walks: 1,
                  activeWalk: false,
                ),
              ),
              child: const Text('prijava'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('prijava'));
      await tester.pumpAndSettle();

      expect(find.textContaining(_ana), findsOneWidget);
      expect(find.textContaining(_bor), findsOneWidget);
      expect(find.text('• zapisi: 2'), findsOneWidget);
      expect(find.text('• obhodi: 1'), findsOneWidget);
      expect(find.textContaining('izbrisi'), findsNothing);

      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('Prekliči answers false', (tester) async {
      expect(await open(tester, 'Prekliči'), isFalse);
    });

    testWidgets('Zavrzi in nadaljuj answers true', (tester) async {
      expect(await open(tester, 'Zavrzi in nadaljuj'), isTrue);
    });
  });
}
