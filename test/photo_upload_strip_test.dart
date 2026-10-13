// TB-51: a photo whose stripped copy could not be written still leaves the
// phone without its EXIF.
//
// `_materializePhotos` keeps the photo when `savePicked` throws (an I/O error
// such as a full disk), still pointing at image_picker's temp file, which
// carries the camera's EXIF. The upload must not send that file as it is.
//
// The failure is real, not faked: `PhotoStorage` gets a root whose parent is a
// plain file, so creating the record's folder throws. The TB-35 lesson applies:
// the test first establishes that the photo POST actually reached the mock.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

bool _has(Uint8List hay, String ascii) {
  final needle = ascii.codeUnits;
  outer:
  for (var i = 0; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tb51_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'a photo that could not be stored uploads stripped, and is kept',
    () async {
      final picked = File('${tmp.path}/image_picker_temp.jpg')
        ..writeAsBytesSync(
          File('test/fixtures/exif_gps_le.jpg').readAsBytesSync(),
        );
      expect(
        _has(picked.readAsBytesSync(), 'samsung'),
        isTrue,
        reason: 'the fixture must carry the EXIF this test looks for',
      );

      // A root under a plain file: creating the record's folder throws.
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('');
      final storage = PhotoStorage(
        rootResolver: () => Directory('${blocker.path}/disturbance_photos'),
      );

      final photoBodies = <Uint8List>[];
      final client = MockClient((req) async {
        if (req.url.path.contains('/photos/')) {
          photoBodies.add(req.bodyBytes);
          return http.Response('', 201);
        }
        if (req.url.path.contains('/walks')) {
          return http.Response(jsonEncode({'walks': <dynamic>[]}), 200);
        }
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'records': <dynamic>[]}), 200);
        }
        return http.Response('', 201);
      });

      final store = _FakeStore();
      final state = AppState(
        localStore: store,
        walksStore: _FakeWalksStore(),
        remoteApi: RemoteApi(client: client),
        connectivity: _OnlineConnectivity(),
        authService: _FakeAuth(),
        photoStorage: storage,
      );
      await state.init();
      await pumpEventQueue();

      await state.addRecord(
        Disturbance(
          id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
          latitude: 45.79,
          longitude: 14.36,
          locationAccuracy: 'Natančna',
          observedAt: DateTime.utc(2026, 10, 13, 9),
          types: const [],
          description: 'opis',
          photos: [
            DisturbancePhoto(
              id: 'ffffffff-0000-1111-2222-333333333333',
              mimeType: 'image/jpeg',
              localPath: picked.path,
              pendingUpload: true,
            ),
          ],
          observers: const [],
          actionTaken: 'Brez ukrepa',
          caseStatus: 'Odprto',
          pendingSync: false,
          createdAt: DateTime.utc(2026, 10, 13, 9),
        ),
      );

      // The failure path ran: the photo still points at the temp file...
      final photo = store.seed.single.photos.single;
      expect(
        photo.localPath,
        picked.path,
        reason: 'savePicked must have failed for this test to mean anything',
      );
      // ...and the upload reached the server.
      expect(photoBodies, hasLength(1));
      expect(
        photo.pendingUpload,
        isFalse,
        reason: 'kept and sent, not dropped',
      );

      final sent = photoBodies.single;
      expect(_has(sent, 'samsung'), isFalse);
      expect(_has(sent, 'SM-A566B'), isFalse);
      expect(_has(sent, 'xmpmeta'), isFalse);
      expect(sent.length, lessThan(picked.lengthSync()));
      expect(sent[0], 0xFF);
      expect(sent[1], 0xD8);
    },
  );
}
