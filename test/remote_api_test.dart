// Unit tests for RemoteApi against the disturbance CRUD endpoints.
//
// We use MockClient (from package:http/testing.dart) to assert the wire
// shape (URL, method, headers, body) and to feed back canned responses for
// each status-code branch (idempotent re-create, 401, 404, 5xx, network
// timeout). The real ORDS endpoint is never touched.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

const _creds = SyncCredentials.token('test-bearer-token-abc123');

final _baseUrl = Uri.parse('https://narcis.gov.si/ords/narcis/disturbances/');

Disturbance _sample({String id = '11111111-2222-3333-4444-555555555555'}) {
  return Disturbance(
    id: id,
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: DateTime.utc(2026, 4, 25, 12, 0, 0),
    types: const [
      SelectedDisturbanceType(
        groupCode: '1',
        groupName: 'Sprehajalci',
        typeCode: 'a',
        typeName: 'Ljudje izven poti',
      ),
    ],
    description: 'Test',
    photos: const [],
    observers: const ['Alexis Zrimec'],
    actionTaken: 'Brez ukrepanja',
    caseStatus: 'Odprto',
    pendingSync: false,
    createdAt: DateTime.utc(2026, 4, 25, 12, 0, 0),
  );
}

RemoteApi _api(Future<http.Response> Function(http.Request) respond) {
  return RemoteApi(
    client: MockClient(respond),
    baseUrl: _baseUrl,
    timeout: const Duration(seconds: 1),
  );
}

void main() {
  group('createRecord', () {
    test('POSTs JSON to base URL with X-Narcis-Auth Bearer header', () async {
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        return http.Response('{"id":"x","status":"created"}', 201);
      });

      await api.createRecord(_sample(), _creds);

      expect(captured.method, 'POST');
      expect(captured.url, _baseUrl);
      expect(captured.headers['X-Narcis-Auth'], 'Bearer test-bearer-token-abc123');
      expect(
        captured.headers['Content-Type'],
        startsWith('application/json'),
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['id'], '11111111-2222-3333-4444-555555555555');
      expect(body['latitude'], 45.79);
      expect(body['longitude'], 14.36);
      expect(body['locationAccuracy'], 'Natančna');
      expect(body['observedAt'], '2026-04-25T12:00:00.000Z');
      expect(body['actionTaken'], 'Brez ukrepanja');
      expect(body['observers'], const ['Alexis Zrimec']);
      // Wire payload trims types to just the codes — names are derivable
      // from the codebook on the server.
      expect(body['types'], const [
        {'groupCode': '1', 'typeCode': 'a'},
      ]);
      // pendingSync, photos, createdAt are not on the wire — photos go up via
      // the dedicated photo endpoint, not the disturbance JSON.
      expect(body.containsKey('pendingSync'), isFalse);
      expect(body.containsKey('photos'), isFalse);
      expect(body.containsKey('createdAt'), isFalse);
    });

    test('200 (idempotent re-create) is treated as success', () async {
      final api = _api((_) async =>
          http.Response('{"id":"x","status":"exists"}', 200));
      // No throw.
      await api.createRecord(_sample(), _creds);
    });

    test('401 throws a RemoteApiException flagged as unauthorized', () async {
      final api = _api((_) async => http.Response('{"error":"unauth"}', 401));
      try {
        await api.createRecord(_sample(), _creds);
        fail('expected throw');
      } on RemoteApiException catch (e) {
        expect(e.isUnauthorized, isTrue);
        expect(e.isNetwork, isFalse);
      }
    });

    test('500 throws a non-network RemoteApiException', () async {
      final api = _api((_) async => http.Response('boom', 500));
      try {
        await api.createRecord(_sample(), _creds);
        fail('expected throw');
      } on RemoteApiException catch (e) {
        expect(e.statusCode, 500);
        expect(e.isNetwork, isFalse);
        expect(e.isUnauthorized, isFalse);
      }
    });

    test('socket failure surfaces as a network exception', () async {
      final api = _api((_) async {
        throw const SocketException('no route');
      });
      try {
        await api.createRecord(_sample(), _creds);
        fail('expected throw');
      } on RemoteApiException catch (e) {
        expect(e.isNetwork, isTrue);
      }
    });
  });

  group('updateRecord', () {
    test('PUTs to disturbances/<id>', () async {
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        return http.Response('{"status":"updated"}', 200);
      });

      await api.updateRecord(_sample(), _creds);

      expect(captured.method, 'PUT');
      expect(captured.url.toString(),
          '${_baseUrl}11111111-2222-3333-4444-555555555555');
    });

    test('non-200 raises', () async {
      final api = _api((_) async => http.Response('{}', 404));
      expect(
        api.updateRecord(_sample(), _creds),
        throwsA(isA<RemoteApiException>()),
      );
    });
  });

  group('deleteRecord', () {
    test('DELETE 204 succeeds', () async {
      final api = _api((_) async => http.Response('', 204));
      await api.deleteRecord('id-1', _creds);
    });

    test('DELETE 404 is treated as success (idempotent delete)', () async {
      final api = _api((_) async => http.Response('{}', 404));
      // No throw - already-gone is the desired end state.
      await api.deleteRecord('id-2', _creds);
    });

    test('DELETE 500 raises', () async {
      final api = _api((_) async => http.Response('boom', 500));
      expect(
        api.deleteRecord('id-3', _creds),
        throwsA(isA<RemoteApiException>()),
      );
    });
  });

  group('fetchRecords', () {
    test('GETs the base URL with auth and parses {"records":[...]}', () async {
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        // utf8 encoding required because the body contains 'č' (Natančna) -
        // http.Response(String, ...) defaults to latin-1 and would fail to
        // serialize.
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'records': [
              {
                'id': 'rec-1',
                'latitude': 45.79,
                'longitude': 14.36,
                'locationAccuracy': 'Natančna',
                'observedAt': '2026-04-25T12:00:00.000Z',
                'createdAt': '2026-04-25T12:01:00.000Z',
                'description': 'd',
                'actionTaken': 'Brez ukrepanja',
                'proposedType': null,
                'types': [
                  {'groupCode': '1', 'typeCode': 'a'},
                ],
                'observers': ['Alexis'],
                'photos': [
                  {'id': 'p-1', 'mimeType': 'image/jpeg'},
                ],
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final result = await api.fetchRecords(_creds);
      expect(captured.method, 'GET');
      expect(captured.url, _baseUrl);
      expect(captured.headers['X-Narcis-Auth'], isNotNull);
      expect(result, hasLength(1));
      expect(result.first.id, 'rec-1');
      expect(result.first.photos, hasLength(1));
      expect(result.first.photos.first.id, 'p-1');
      expect(result.first.photos.first.localPath, isNull);
    });

    test('also accepts a bare array body', () async {
      final api = _api((_) async => http.Response('[]', 200));
      final result = await api.fetchRecords(_creds);
      expect(result, isEmpty);
    });

    test('401 surfaces as unauthorized', () async {
      final api = _api((_) async => http.Response('{}', 401));
      try {
        await api.fetchRecords(_creds);
        fail('expected throw');
      } on RemoteApiException catch (e) {
        expect(e.isUnauthorized, isTrue);
      }
    });
  });

  group('photo endpoints', () {
    test('uploadPhoto POSTs binary to /<id>/photos/<photoId>', () async {
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        return http.Response('{"status":"created"}', 201);
      });

      await api.uploadPhoto(
        motnjaId: 'rec-1',
        photoId: 'p-1',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        mimeType: 'image/jpeg',
        credentials: _creds,
      );
      expect(captured.method, 'POST');
      expect(captured.url.toString(), '${_baseUrl}rec-1/photos/p-1');
      expect(captured.headers['Content-Type'], 'image/jpeg');
      expect(captured.bodyBytes, Uint8List.fromList([1, 2, 3, 4]));
    });

    test('uploadPhoto 200 (idempotent re-upload) is treated as success',
        () async {
      final api =
          _api((_) async => http.Response('{"status":"exists"}', 200));
      await api.uploadPhoto(
        motnjaId: 'rec-1',
        photoId: 'p-1',
        bytes: Uint8List.fromList([1]),
        mimeType: 'image/jpeg',
        credentials: _creds,
      );
    });

    test('downloadPhoto returns the response bytes', () async {
      final api = _api(
        (_) async => http.Response.bytes(
          [9, 8, 7],
          200,
          headers: {'content-type': 'image/jpeg'},
        ),
      );
      final bytes = await api.downloadPhoto(
        motnjaId: 'rec-1',
        photoId: 'p-1',
        credentials: _creds,
      );
      expect(bytes, Uint8List.fromList([9, 8, 7]));
    });

    test('deletePhoto treats 404 as already-gone', () async {
      final api = _api((_) async => http.Response('', 404));
      await api.deletePhoto(
        motnjaId: 'rec-1',
        photoId: 'p-1',
        credentials: _creds,
      );
    });
  });

  group('SyncCredentials', () {
    test('token() builds a Bearer header', () {
      expect(
        const SyncCredentials.token('abc123').authHeaderValue,
        'Bearer abc123',
      );
    });

    test('basic() builds a Basic base64(email:password) header', () {
      final expected =
          'Basic ${base64Encode(utf8.encode('alice@example.com:pw'))}';
      expect(
        SyncCredentials.basic(email: 'alice@example.com', password: 'pw')
            .authHeaderValue,
        expected,
      );
    });
  });

  // TB-13: synced times come back from the server Z-tagged (UTC). Display code
  // must .toLocal() them or it renders the UTC wall-clock (off by the CET/CEST
  // offset). These tests pin the parse-boundary contract that makes the
  // display-site .toLocal() both necessary and correct, and that a full
  // local -> wire -> parse -> toLocal round-trip recovers the original instant.
  group('timestamp round-trip (TB-13)', () {
    test('server Z-tagged observedAt parses to a UTC instant', () async {
      final api = _api((_) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'records': [
                {
                  'id': 'rec-1',
                  'latitude': 45.79,
                  'longitude': 14.36,
                  'locationAccuracy': 'Natančna',
                  'observedAt': '2026-04-25T12:00:00.000Z',
                  'actionTaken': 'Brez ukrepanja',
                  'types': const [],
                  'observers': const [],
                },
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));

      final rec = (await api.fetchRecords(_creds)).single;
      expect(rec.observedAt.isUtc, isTrue);
      expect(rec.observedAt, DateTime.utc(2026, 4, 25, 12, 0, 0));
    });

    test('local -> UTC wire -> parse -> toLocal recovers the wall-clock', () {
      // A freshly created record holds a *local* DateTime; the client POSTs it
      // as UTC (toUtc().toIso8601String(), remote_api.dart) and the server
      // echoes that Z-tagged instant. Displaying it back must show the same
      // wall-clock the warden entered — which is exactly what the display-site
      // .toLocal() restores. TZ-independent: toUtc()/toLocal() are inverses.
      final entered = DateTime(2026, 6, 22, 14, 30); // local
      final wire = entered.toUtc().toIso8601String();
      expect(wire, endsWith('Z'));

      final parsed = DateTime.parse(wire);
      expect(parsed.isUtc, isTrue);
      expect(parsed.isAtSameMomentAs(entered), isTrue);

      final fmt = DateFormat('dd.MM.yyyy HH:mm');
      expect(fmt.format(parsed.toLocal()), fmt.format(entered));
    });
  });

  group('case review fields (TB-26)', () {
    Future<RemoteDisturbance> fetchOne(Map<String, dynamic> extra) async {
      final api = _api((_) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'records': [
                {
                  'id': 'rec-1',
                  'latitude': 45.79,
                  'longitude': 14.36,
                  'locationAccuracy': 'Natančna',
                  'observedAt': '2026-08-20T09:00:00.000Z',
                  'createdAt': '2026-08-20T09:01:00.000Z',
                  'description': 'd',
                  'actionTaken': 'Brez ukrepanja',
                  'caseStatus': 'Zaključeno',
                  'types': const [],
                  'observers': const [],
                  'photos': const [],
                  ...extra,
                },
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final result = await api.fetchRecords(_creds);
      return result.single;
    }

    test('reviewedBy / reviewedAt parse, and reviewedAt is a UTC instant',
        () async {
      final r = await fetchOne({
        'reviewedBy': 'referent@gov.si',
        'reviewedAt': '2026-08-26T14:30:00.000Z',
      });
      expect(r.reviewedBy, 'referent@gov.si');
      expect(r.reviewedAt!.isUtc, isTrue);
      expect(r.reviewedAt, DateTime.utc(2026, 8, 26, 14, 30));
      // and survives the hop into the local-store shape the UI reads
      expect(r.toLocal().reviewedBy, 'referent@gov.si');
      expect(r.toLocal().reviewedAt, DateTime.utc(2026, 8, 26, 14, 30));
    });

    test('an unreviewed record omits both keys entirely -> null', () async {
      // APEX_JSON elides NULL-valued keys, so these arrive absent, not null.
      final r = await fetchOne(const {});
      expect(r.reviewedBy, isNull);
      expect(r.reviewedAt, isNull);
      expect(r.toLocal().reviewedBy, isNull);
      expect(r.toLocal().reviewedAt, isNull);
    });

    test('the review fields NEVER go back on the wire in a write', () async {
      // The web backoffice is their sole writer (narcis-vibed NV-220). If they
      // ever appear in _payload, this app could clobber a reviewer's decision.
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        return http.Response('{"ok":true}', req.method == 'POST' ? 201 : 200);
      });
      final reviewed = _sample().copyWith(
        caseStatus: 'Zaključeno',
        reviewedBy: 'referent@gov.si',
        reviewedAt: DateTime.utc(2026, 8, 26, 14, 30),
      );
      expect(reviewed.reviewedBy, isNotNull); // guard: the fixture is reviewed

      await api.createRecord(reviewed, _creds);
      final post = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(post.containsKey('reviewedBy'), isFalse);
      expect(post.containsKey('reviewedAt'), isFalse);

      await api.updateRecord(reviewed, _creds);
      final put = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(put.containsKey('reviewedBy'), isFalse);
      expect(put.containsKey('reviewedAt'), isFalse);
    });

    test('local-store JSON round-trips both fields', () {
      final before = _sample().copyWith(
        reviewedBy: 'referent@gov.si',
        reviewedAt: DateTime.utc(2026, 8, 26, 14, 30),
      );
      final after = Disturbance.fromJson(
          jsonDecode(jsonEncode(before.toJson())) as Map<String, dynamic>);
      expect(after.reviewedBy, 'referent@gov.si');
      expect(after.reviewedAt, DateTime.utc(2026, 8, 26, 14, 30));
    });

    test('a record cached before TB-26 rehydrates with nulls', () {
      final legacy = _sample().toJson()
        ..remove('reviewedBy')
        ..remove('reviewedAt');
      final after = Disturbance.fromJson(legacy);
      expect(after.reviewedBy, isNull);
      expect(after.reviewedAt, isNull);
    });
  });
}

/// Local stand-in for dart:io's SocketException so we don't depend on
/// a non-pure import.
class SocketException implements Exception {
  const SocketException(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}
