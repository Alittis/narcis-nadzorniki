// TB-49: logging out removes the photos from the device, not just the records
// that pointed at them.
//
// Unlike logout_guard_test.dart this calls the real `AppState.logout()`. The
// two plugins it reaches are stood in for: the foreground-task channel answers
// "no walk running", and the auth cache is in memory.

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

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

class _MemCache implements AuthCacheStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeLegacy extends LegacyRecordsLoader {
  @override
  Future<List<LegacyDisturbance>> load() async => const [];
}

class _OfflineConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.none,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tb49_');
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

  test('logout deletes every photo file, own and teammates\'', () async {
    final root = Directory('${tmp.path}/disturbance_photos');
    final own = File('${root.path}/m-own/f1.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    final teammate = File('${root.path}/m-other/f2.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);

    final state = AppState(
      localStore: _FakeStore(),
      walksStore: _FakeWalksStore(),
      connectivity: _OfflineConnectivity(),
      authService: AuthService(
        client: MockClient((_) async => http.Response('', 200)),
        cacheStore: _MemCache(),
      ),
      legacyLoader: _FakeLegacy(),
      photoStorage: PhotoStorage(rootResolver: () => root),
    );
    await state.init();

    await state.logout();

    expect(own.existsSync(), isFalse);
    expect(teammate.existsSync(), isFalse);
    expect(root.existsSync(), isFalse);
  });

  test('the next photo after a logout still has somewhere to go', () async {
    final root = Directory('${tmp.path}/disturbance_photos');
    final storage = PhotoStorage(rootResolver: () => root);
    await storage.deleteAll();

    final src = File('${tmp.path}/picked.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    final path = await storage.savePicked(
      motnjaId: 'm1',
      photoId: 'f1',
      sourcePath: src.path,
      mimeType: 'image/jpeg',
    );

    expect(File(path).existsSync(), isTrue);
  });
}
