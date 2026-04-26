// Unit tests for RemoteApi against the disturbance CRUD endpoints.
//
// We use MockClient (from package:http/testing.dart) to assert the wire
// shape (URL, method, headers, body) and to feed back canned responses for
// each status-code branch (idempotent re-create, 401, 404, 5xx, network
// timeout). The real ORDS endpoint is never touched.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

const _creds = SyncCredentials(
  email: 'alexis.zrimec@gov.si',
  password: 'hunter2',
);

final _baseUrl = Uri.parse('https://narcis.gov.si/ords/narcis/disturbances/');

Disturbance _sample({String id = '11111111-2222-3333-4444-555555555555'}) {
  return Disturbance(
    id: id,
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'natancna',
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
    photoPaths: const [],
    observers: const ['Alexis Zrimec'],
    actionTaken: 'brez',
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
    test('POSTs JSON to base URL with X-Narcis-Auth Basic header', () async {
      late http.Request captured;
      final api = _api((req) async {
        captured = req;
        return http.Response('{"id":"x","status":"created"}', 201);
      });

      await api.createRecord(_sample(), _creds);

      expect(captured.method, 'POST');
      expect(captured.url, _baseUrl);
      // Basic <base64("alexis.zrimec@gov.si:hunter2")>
      final expected =
          'Basic ${base64Encode(utf8.encode('${_creds.email}:${_creds.password}'))}';
      expect(captured.headers['X-Narcis-Auth'], expected);
      expect(
        captured.headers['Content-Type'],
        startsWith('application/json'),
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['id'], '11111111-2222-3333-4444-555555555555');
      expect(body['latitude'], 45.79);
      expect(body['longitude'], 14.36);
      expect(body['locationAccuracy'], 'natancna');
      expect(body['observedAt'], '2026-04-25T12:00:00.000Z');
      expect(body['actionTaken'], 'brez');
      expect(body['observers'], const ['Alexis Zrimec']);
      // Wire payload trims types to just the codes — names are derivable
      // from the codebook on the server.
      expect(body['types'], const [
        {'groupCode': '1', 'typeCode': 'a'},
      ]);
      // pendingSync, photoPaths, createdAt are not on the wire.
      expect(body.containsKey('pendingSync'), isFalse);
      expect(body.containsKey('photoPaths'), isFalse);
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
}

/// Local stand-in for dart:io's SocketException so we don't depend on
/// a non-pure import.
class SocketException implements Exception {
  const SocketException(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}
