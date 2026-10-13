// TB-53 and TB-52: a photo waiting to upload is not lost without a word.
//
// TB-53: the pull used to keep only the photos the server reported, so a photo
// whose upload failed in a sync whose pull then succeeded vanished from its
// record, with the badge green and the file orphaned on disk.
//
// TB-52: a photo whose stable copy failed (TB-51) sits on image_picker's cache
// file. The copy is retried, and if the file is gone the photo is dropped on
// purpose and the user told once (owner decision 2026-10-13).
//
// The TB-35 rule applies: each test establishes that the requests it depends
// on actually reached the mock.

import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/lost_photos_dialog.dart';

const _id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _photoId = 'ffffffff-0000-1111-2222-333333333333';

Disturbance _rec({String? photoPath, List<SelectedDisturbanceType>? types}) =>
    Disturbance(
      id: _id,
      latitude: 45.79,
      longitude: 14.36,
      locationAccuracy: 'Natančna',
      observedAt: DateTime.utc(2026, 10, 13, 9),
      types: types ?? const [],
      description: 'opis',
      photos: [
        if (photoPath != null)
          DisturbancePhoto(
            id: _photoId,
            mimeType: 'image/jpeg',
            localPath: photoPath,
            pendingUpload: true,
          ),
      ],
      observers: const [],
      actionTaken: 'Brez ukrepa',
      caseStatus: 'Odprto',
      pendingSync: false,
      createdAt: DateTime.utc(2026, 10, 13, 9),
    );

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
}

class _FakeAuth extends AuthService {
  @override
  Future<StoredSession?> readStoredSession() async =>
      const StoredSession(email: 'warden@gov.si', token: 'tok');
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

/// A booted online AppState against a server that remembers what it was sent:
/// the GET list reports the record once it is created, with the photos that
/// uploaded. `photoStatus` is mutable so a test can fail uploads, then not.
class _Harness {
  _Harness(this.storage);

  final PhotoStorage storage;
  final store = _FakeStore();
  final requests = <String>[];
  final uploaded = <String>{};
  int photoStatus = 201;
  bool _created = false;
  late final AppState state;

  /// UTF-8 explicitly: the record carries `Natančna` (see TB-35).
  static http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<void> boot() async {
    final client = MockClient((req) async {
      final path = req.url.path;
      requests.add('${req.method} $path');
      if (path.contains('/photos/')) {
        if (photoStatus == 201) uploaded.add(path.split('/').last);
        return http.Response('', photoStatus);
      }
      if (path.contains('/walks')) return _json({'walks': <dynamic>[]});
      if (req.method == 'GET') {
        return _json({
          'records': [
            if (_created)
              {
                'id': _id,
                'latitude': 45.79,
                'longitude': 14.36,
                'locationAccuracy': 'Natančna',
                'observedAt': '2026-10-13T09:00:00.000Z',
                'types': <dynamic>[],
                'description': 'opis',
                'observers': <dynamic>[],
                'actionTaken': 'Brez ukrepa',
                'caseStatus': 'Odprto',
                'createdAt': '2026-10-13T09:00:00.000Z',
                'createdBy': 'warden@gov.si',
                'photos': [
                  for (final p in uploaded) {'id': p, 'mimeType': 'image/jpeg'},
                ],
              },
          ],
        });
      }
      _created = true;
      return http.Response('', 201);
    });
    state = AppState(
      localStore: store,
      walksStore: _FakeWalksStore(),
      remoteApi: RemoteApi(client: client),
      connectivity: _OnlineConnectivity(),
      authService: _FakeAuth(),
      photoStorage: storage,
    );
    await state.init();
    await pumpEventQueue();
  }

  /// Saves the record offline, so nothing is sent until [goOnline].
  Future<void> addOffline(Disturbance record) async {
    state.setOfflineOverride(true);
    await state.addRecord(record);
  }

  Future<void> goOnline() async {
    state.setOfflineOverride(false); // starts a syncAll, not awaited
    // Wait for it rather than pump a fixed number of turns: it does real file
    // I/O, which a fixed pump can outrun.
    while (state.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  int get photoPosts => requests
      .where((r) => r.startsWith('POST') && r.contains('/photos/'))
      .length;

  DisturbancePhoto? get photo => store.seed.single.photos.firstOrNull;
}

void main() {
  late Directory tmp;
  late File picked;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tb52_53_');
    picked = File('${tmp.path}/image_picker_temp.jpg')
      ..writeAsBytesSync(
        File('test/fixtures/exif_gps_le.jpg').readAsBytesSync(),
      );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('TB-53', () {
    test('a photo whose upload fails stays on its record through the pull, '
        'and uploads later', () async {
      final h = _Harness(
        PhotoStorage(rootResolver: () => Directory('${tmp.path}/photos')),
      )..photoStatus = 500;
      await h.boot();

      await h.state.addRecord(_rec(photoPath: picked.path));
      await h.state.syncAll();

      // The upload failed twice and a pull ran after the second failure.
      expect(h.photoPosts, 2);
      final lastPhotoPost = h.requests.lastIndexWhere(
        (r) => r.contains('/photos/'),
      );
      expect(
        h.requests.sublist(lastPhotoPost),
        contains('GET /ords/narcis/disturbances/'),
        reason: 'the pull must have run for this test to mean anything',
      );
      expect(h.photo, isNotNull, reason: 'the pull must not drop it');
      expect(h.photo!.pendingUpload, isTrue);
      expect(h.state.pendingPushCount, 1);

      h.photoStatus = 201;
      await h.state.syncAll();

      expect(h.photo!.id, _photoId);
      expect(h.photo!.pendingUpload, isFalse);
      expect(h.state.pendingPushCount, 0);
    });
  });

  group('TB-52', () {
    test(
      'a photo whose copy failed is copied once storage works again',
      () async {
        // A plain file where the photo root's parent should be: the copy fails.
        final blocker = File('${tmp.path}/blocker')..writeAsStringSync('');
        final root = Directory('${blocker.path}/photos');
        final h = _Harness(PhotoStorage(rootResolver: () => root));
        await h.boot();

        await h.addOffline(_rec(photoPath: picked.path));
        expect(
          h.photo!.localPath,
          picked.path,
          reason: 'the first copy failed',
        );

        blocker.deleteSync();
        await h.goOnline();

        expect(h.photoPosts, 1);
        expect(h.photo!.pendingUpload, isFalse);
        expect(h.photo!.localPath, startsWith('${root.path}/'));
        expect(File(h.photo!.localPath!).existsSync(), isTrue);
      },
    );

    test('a photo whose file is gone is dropped and announced once, '
        'and nothing is sent', () async {
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('');
      final h = _Harness(
        PhotoStorage(rootResolver: () => Directory('${blocker.path}/photos')),
      );
      await h.boot();

      await h.addOffline(_rec(photoPath: picked.path));
      expect(h.photo!.localPath, picked.path, reason: 'the copy failed');
      picked.deleteSync(); // Android cleared the cache
      await h.goOnline();

      expect(
        h.requests,
        contains('POST /ords/narcis/disturbances/'),
        reason: 'the sync must have run for this test to mean anything',
      );
      expect(h.photoPosts, 0);
      expect(h.store.seed.single.photos, isEmpty);
      expect(h.state.pendingPushCount, 0, reason: 'nothing left to send');

      final lost = h.state.takeLostPhotos();
      expect(lost.photos, 1);
      expect(lost.records.map((r) => r.id), [_id]);
      expect(h.state.takeLostPhotos().isEmpty, isTrue, reason: 'only once');
    });

    testWidgets('the notice names the record', (tester) async {
      const type = SelectedDisturbanceType(
        groupCode: 'G',
        groupName: 'Skupina',
        typeCode: 'T',
        typeName: 'Odlaganje odpadkov',
      );
      final record = _rec(types: const [type]);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLostPhotosDialog(
                context,
                LostPhotos(photos: 1, records: [record]),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Fotografije ni bilo mogoče poslati'), findsOneWidget);
      final local = record.observedAt.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final date =
          '${two(local.day)}.${two(local.month)}.${local.year} '
          '${two(local.hour)}:${two(local.minute)}';
      expect(
        find.textContaining(
          'Zapis je shranjen brez nje:\n\n'
          '• $date · Odlaganje odpadkov',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Razumem'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
