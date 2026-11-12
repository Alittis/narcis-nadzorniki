// TB-59 (narcis-racun RN-22 S3): the phone counts the sync and upload failures
// a signed-in person hits, per (folded path, kind), and reports the counts to
// `POST /api/beleznica/app/v1/tezave` after the next successful sync. The
// counts stay until a 204; nothing of a record, photo or typed text is sent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/tezave_store.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

const _creds = SyncCredentials.token('tok');
const _base = '/api/beleznica/app/v1';
const _id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _photoId = 'ffffffff-0000-1111-2222-333333333333';
const _records = '$_base/disturbances';
const _photo = '$_base/disturbances/:id/photos/:id';

RemoteApi _api(Future<http.Response> Function(http.Request) respond) =>
    RemoteApi(
      client: MockClient(respond),
      apiBase: Uri.parse('https://narcis.alittis.com$_base'),
      timeout: const Duration(milliseconds: 200),
    );

Future<RemoteApiException> _failure(
  Future<void> Function(RemoteApi api) call,
  Future<http.Response> Function(http.Request) respond,
) async {
  try {
    await call(_api(respond));
  } on RemoteApiException catch (e) {
    return e;
  }
  fail('expected a RemoteApiException');
}

Disturbance _rec({List<DisturbancePhoto> photos = const []}) => Disturbance(
  id: _id,
  latitude: 45.79,
  longitude: 14.36,
  locationAccuracy: 'Natančna',
  observedAt: DateTime.utc(2026, 11, 12, 9),
  types: const [],
  description: 'skrivni opis',
  photos: photos,
  observers: const ['Opazovalka'],
  actionTaken: 'Brez ukrepa',
  caseStatus: 'Odprto',
  pendingSync: false,
  createdAt: DateTime.utc(2026, 11, 12, 9),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final stores = <TezaveStore>[];
  setUp(() => tmp = Directory.systemTemp.createTempSync('tb59_'));
  tearDown(() async {
    // A write still pending must not land after the folder is gone.
    await Future.wait([for (final s in stores) s.saved]);
    stores.clear();
    tmp.deleteSync(recursive: true);
  });

  TezaveStore store() {
    final dir = tmp; // this test's folder, not whichever is current later
    final s = TezaveStore(directory: () async => dir);
    stores.add(s);
    return s;
  }

  group('counting', () {
    test('counts per (pot, koda), in the order kinds first occur', () {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network')
        ..record(account: 'a@gov.si', pot: _photo, koda: 'http_5xx')
        ..record(account: 'a@gov.si', pot: _records, koda: 'network')
        ..record(account: 'a@gov.si', pot: _records, koda: 'http_5xx');
      expect(s.pending, const [
        Tezava(pot: _records, koda: 'network', stevilo: 2),
        Tezava(pot: _photo, koda: 'http_5xx', stevilo: 1),
        Tezava(pot: _records, koda: 'http_5xx', stevilo: 1),
      ]);
    });

    test('a pot or koda the route would refuse is not counted', () {
      final s = store()
        ..record(account: 'a@gov.si', pot: '$_records?q=x', koda: 'network')
        ..record(account: 'a@gov.si', pot: 'no-leading-slash', koda: 'x')
        ..record(account: 'a@gov.si', pot: _records, koda: 'two words')
        ..record(account: 'a@gov.si', pot: _records, koda: '');
      expect(s.pending, isEmpty);
    });

    test('a failure for another account drops what the first one left', () {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network')
        ..record(account: 'B@gov.si', pot: _photo, koda: 'photo_lost');
      expect(s.pending, const [
        Tezava(pot: _photo, koda: 'photo_lost', stevilo: 1),
      ]);
    });

    test('the counts survive a restart', () async {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network')
        ..record(account: 'a@gov.si', pot: _records, koda: 'network');
      await s.saved;
      final again = store();
      await again.load();
      expect(again.pending, const [
        Tezava(pot: _records, koda: 'network', stevilo: 2),
      ]);
    });
  });

  group('the cap', () {
    test('a count stops at 1000', () {
      final s = store();
      for (var i = 0; i < 1500; i++) {
        s.record(account: 'a@gov.si', pot: _records, koda: 'network');
      }
      expect(s.pending.single.stevilo, TezaveStore.maxCount);
    });

    test('at most 50 kinds; a new kind beyond them is not counted, '
        'the ones already there still are', () {
      final s = store();
      for (var i = 0; i < 60; i++) {
        s.record(account: 'a@gov.si', pot: _records, koda: 'http_$i');
      }
      s.record(account: 'a@gov.si', pot: _records, koda: 'http_0');
      expect(s.pending, hasLength(TezaveStore.maxEntries));
      expect(s.pending.first.stevilo, 2);
      expect(s.pending.map((t) => t.koda), isNot(contains('http_55')));
    });
  });

  group('send, then clear', () {
    test('a report the server took clears what it carried', () async {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network');
      List<Tezava>? sent;
      await s.flush('a@gov.si', (t) async => sent = t);
      expect(sent, const [Tezava(pot: _records, koda: 'network', stevilo: 1)]);
      expect(s.pending, isEmpty);
      final again = store();
      await again.load();
      expect(again.pending, isEmpty, reason: 'the file is cleared too');
    });

    test('a report not taken keeps everything', () async {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network');
      await s.flush('a@gov.si', (_) async => throw Exception('500'));
      expect(s.pending.single.stevilo, 1);
    });

    test('a failure counted while the report is in flight is kept', () async {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network');
      final gate = Completer<void>();
      final flushing = s.flush('a@gov.si', (_) => gate.future);
      s
        ..record(account: 'a@gov.si', pot: _records, koda: 'network')
        ..record(account: 'a@gov.si', pot: _photo, koda: 'photo_upload');
      // A second flush while the first is in flight sends nothing.
      var second = false;
      await s.flush('a@gov.si', (_) async => second = true);
      expect(second, isFalse);
      gate.complete();
      await flushing;
      expect(s.pending, const [
        Tezava(pot: _records, koda: 'network', stevilo: 1),
        Tezava(pot: _photo, koda: 'photo_upload', stevilo: 1),
      ]);
    });

    test('counts of another account are discarded, never sent', () async {
      final s = store()
        ..record(account: 'a@gov.si', pot: _records, koda: 'network');
      var sent = false;
      await s.flush('b@gov.si', (_) async => sent = true);
      expect(sent, isFalse);
      expect(s.pending, isEmpty);
    });
  });

  group('folding', () {
    final api = _api((_) async => http.Response('', 200));
    Uri at(String path) => Uri.parse('https://narcis.alittis.com$path');

    test('ids become :id, resource names and the API base stay', () {
      expect(api.foldPath(at(_records)), _records);
      expect(api.foldPath(at('$_records/$_id')), '$_records/:id');
      expect(api.foldPath(at('$_records/$_id/photos/$_photoId')), _photo);
      expect(
        api.foldPath(at('$_base/walks/$_id/points')),
        '$_base/walks/:id/points',
      );
      expect(api.photoPot, _photo);
    });

    test('a query string and any unknown segment never pass', () {
      expect(api.foldPath(at('$_records/x?email=a@gov.si')), '$_records/:id');
      expect(api.foldPath(at('$_base/opis besedilo')), '$_base/:id');
    });

    test('a failed request carries its folded path and its kind', () async {
      Future<void> upload(RemoteApi a) => a.uploadPhoto(
        motnjaId: _id,
        photoId: _photoId,
        bytes: Uint8List(1),
        mimeType: 'image/jpeg',
        credentials: _creds,
      );
      var e = await _failure(upload, (_) async => http.Response('', 503));
      expect((e.pot, e.koda), (_photo, 'http_5xx'));
      e = await _failure(upload, (_) async => throw const SocketException('x'));
      expect((e.pot, e.koda), (_photo, 'network'));
      e = await _failure(
        (a) => a.createRecord(_rec(), _creds),
        (_) async => http.Response('', 426),
      );
      expect((e.pot, e.koda), (_records, 'http_426'));
      e = await _failure(
        (a) => a.fetchWalkPoints(_id, _creds),
        (_) async => http.Response('', 404),
      );
      expect((e.pot, e.koda), ('$_base/walks/:id/points', 'http_404'));
      e = await _failure(
        (a) => a.updateRecord(_rec(), _creds),
        (_) async => http.Response('', 401),
      );
      expect((e.pot, e.koda), ('$_records/:id', 'http_401'));
      e = await _failure(
        (a) => a.fetchRecords(_creds),
        (_) => Completer<http.Response>().future, // never answers
      );
      expect((e.pot, e.koda), (_records, 'network'));
    });
  });

  group('sendTezave', () {
    const one = [Tezava(pot: _records, koda: 'network', stevilo: 3)];

    test('POSTs {tezave: [...]} with the Bearer; a 204 completes', () async {
      late http.Request seen;
      await _api((req) async {
        seen = req;
        return http.Response('', 204);
      }).sendTezave(one, _creds);
      expect(seen.method, 'POST');
      expect(seen.url.path, '$_base/tezave');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen.body), {
        'tezave': [
          {'pot': _records, 'koda': 'network', 'stevilo': 3},
        ],
      });
    });

    test('any other answer, or none, throws', () async {
      for (final status in [200, 201, 400, 401, 404, 426, 500]) {
        await expectLater(
          _api((_) async => http.Response('', status)).sendTezave(one, _creds),
          throwsA(isA<RemoteApiException>()),
          reason: '$status',
        );
      }
      await expectLater(
        _api((_) => Completer<http.Response>().future).sendTezave(one, _creds),
        throwsA(isA<RemoteApiException>()),
      );
    });
  });

  group('AppState', () {
    test(
      'a failed create is reported after the next successful sync, with '
      'nothing of the record; a report not taken is retried, then cleared',
      () async {
        final h = _Harness(tmp, store());
        await h.boot();
        h.createStatus = 500;
        await h.state.addRecord(_rec());
        await h.syncAndSettle();
        expect(h.tezaveBodies, hasLength(1));
        expect(jsonDecode(h.tezaveBodies.single), {
          'tezave': [
            // The inline push in addRecord, then the push in syncAll.
            {'pot': _records, 'koda': 'http_5xx', 'stevilo': 2},
          ],
        });
        for (final secret in ['skrivni opis', 'Opazovalka', '45.79', _id]) {
          expect(h.tezaveBodies.single, isNot(contains(secret)));
        }
        expect(h.tezave.pending, isNotEmpty, reason: 'the stub answered 500');

        h
          ..createStatus = 201
          ..tezaveStatus = 204;
        await h.syncAndSettle();
        expect(h.tezaveBodies, hasLength(2));
        expect(jsonDecode(h.tezaveBodies.last), {
          'tezave': [
            {'pot': _records, 'koda': 'http_5xx', 'stevilo': 2},
          ],
        });
        expect(h.tezave.pending, isEmpty);

        await h.syncAndSettle();
        expect(h.tezaveBodies, hasLength(2), reason: 'nothing left to report');
      },
    );

    test('a refused photo upload and a lost photo are counted on the photo '
        'path', () async {
      final picked = File('${tmp.path}/picked.jpg')
        ..writeAsBytesSync(
          File('test/fixtures/exif_gps_le.jpg').readAsBytesSync(),
        );
      final h = _Harness(tmp, store())..photoStatus = 500;
      await h.boot();
      await h.state.addRecord(
        _rec(
          photos: [
            DisturbancePhoto(
              id: _photoId,
              mimeType: 'image/jpeg',
              localPath: picked.path,
              pendingUpload: true,
            ),
            DisturbancePhoto(
              id: _id,
              mimeType: 'image/jpeg',
              localPath: '${tmp.path}/gone.jpg',
              pendingUpload: true,
            ),
          ],
        ),
      );
      await h.syncAndSettle();
      expect(jsonDecode(h.tezaveBodies.single), {
        'tezave': [
          // The upload after the inline create, then the one in syncAll.
          {'pot': _photo, 'koda': 'http_5xx', 'stevilo': 2},
          {'pot': _photo, 'koda': 'photo_lost', 'stevilo': 1},
        ],
      });
    });

    test('nothing is reported while the pull fails; the counts wait', () async {
      final h = _Harness(tmp, store());
      await h.boot();
      h
        ..createStatus = 500
        ..pullStatus = 503;
      await h.state.addRecord(_rec());
      await h.syncAndSettle();
      expect(h.tezaveBodies, isEmpty);
      // The inline push, the push in syncAll and the failed records pull on
      // one path; the failed walks pull on its own.
      expect(h.tezave.pending, const [
        Tezava(pot: _records, koda: 'http_5xx', stevilo: 3),
        Tezava(pot: '$_base/walks', koda: 'http_5xx', stevilo: 1),
      ]);
    });

    test('a report that hangs does not hold up the sync', () async {
      final h = _Harness(tmp, store())..tezaveHangs = true;
      await h.boot();
      h.createStatus = 500;
      await h.state.addRecord(_rec());
      await h.state.syncAll().timeout(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(h.tezaveBodies, hasLength(1), reason: 'it was sent');
      expect(h.state.isSyncing, isFalse);
    });

    test('logout forgets the counts', () async {
      const fgs = MethodChannel('flutter_foreground_task/methods');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        fgs,
        (call) async => call.method == 'isRunningService' ? false : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(fgs, null));
      final h = _Harness(tmp, store());
      await h.boot();
      h.createStatus = 500;
      await h.state.addRecord(_rec());
      expect(h.tezave.pending, isNotEmpty);
      await h.state.logout();
      expect(h.tezave.pending, isEmpty);
    });
  });
}

class _FakeStore extends LocalStore {
  List<Disturbance> seed = [];
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
  @override
  Future<void> clearActive() async {}
}

class _FakeAuth extends AuthService {
  @override
  Future<StoredSession?> readStoredSession() async =>
      const StoredSession(email: 'warden@gov.si', token: 'tok');
  @override
  Future<void> revokeToken(String token) async {}
  @override
  Future<void> clearCache() async {}
}

class _OnlineConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

/// A booted online AppState against a stub of the phone API.
class _Harness {
  _Harness(this.tmp, this.tezave);

  final Directory tmp;
  final TezaveStore tezave;
  final tezaveBodies = <String>[];
  int createStatus = 201;
  int photoStatus = 201;
  int pullStatus = 200;
  int tezaveStatus = 500;
  bool tezaveHangs = false;
  late final AppState state;

  Future<void> boot() async {
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/tezave')) {
        tezaveBodies.add(req.body);
        if (tezaveHangs) return Completer<http.Response>().future;
        return http.Response('', tezaveStatus);
      }
      if (req.method == 'GET') {
        if (pullStatus != 200) return http.Response('', pullStatus);
        return http.Response(
          jsonEncode(
            path.endsWith('/walks')
                ? {'walks': <dynamic>[]}
                : {'records': <dynamic>[]},
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.contains('/photos/')) return http.Response('', photoStatus);
      return http.Response('', createStatus);
    });
    state = AppState(
      localStore: _FakeStore(),
      walksStore: _FakeWalksStore(),
      remoteApi: RemoteApi(client: client, timeout: const Duration(seconds: 5)),
      connectivity: _OnlineConnectivity(),
      authService: _FakeAuth(),
      photoStorage: PhotoStorage(
        rootResolver: () => Directory('${tmp.path}/photos'),
      ),
      tezaveStore: tezave,
    );
    await state.init();
    await pumpEventQueue();
  }

  /// A sync, then the background report it starts.
  Future<void> syncAndSettle() async {
    await state.syncAll();
    await pumpEventQueue();
  }
}
