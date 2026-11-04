// TB-47: the served style and sprite (NV-546) are revalidated by ETag and kept
// on the device per tone, so the Območja layer opens without the network and
// still draws offline from cached tiles. Plus the sprite atlas the layer draws
// with: the served sheet, and the converted circle layers' dots below it.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narcis_nadzorniki/data/zos_style_store.dart';
import 'package:narcis_nadzorniki/widgets/zos_layer.dart';

final _style = File('test/fixtures/zos/style-light.json').readAsBytesSync();
final _index = File('test/fixtures/zos/sprite@2x.json').readAsBytesSync();
final _png = File('test/fixtures/zos/sprite@2x.png').readAsBytesSync();

/// The VPS: the light style with ETag "e1", and its sprite.
MockClient _vps(List<http.Request> seen, {int styleStatus = 200}) =>
    MockClient((req) async {
      seen.add(req);
      final path = req.url.path;
      if (path == '/api/layers/zos-style') {
        if (styleStatus != 200) return http.Response('', styleStatus);
        if (req.headers['if-none-match'] == '"e1"') {
          return http.Response('', 304);
        }
        return http.Response.bytes(_style, 200, headers: {'etag': '"e1"'});
      }
      if (path.endsWith('/sprite@2x.json')) {
        return http.Response.bytes(_index, 200);
      }
      if (path.endsWith('/sprite@2x.png')) return http.Response.bytes(_png, 200);
      return http.Response('', 404);
    });

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('zos_style'));
  tearDown(() => dir.delete(recursive: true));

  ZosStyleStore store(MockClient client) =>
      ZosStyleStore(client: client, directory: () async => dir);

  test('a first fetch brings the style and its sprite, and keeps them',
      () async {
    final seen = <http.Request>[];
    final b = await store(_vps(seen)).refresh(ZosTone.light);
    expect(seen.map((r) => r.url.toString()), [
      '$kZosOrigin/api/layers/zos-style?tone=light',
      '$kZosOrigin/api/layers/zos-sprite/sprite@2x.json',
      '$kZosOrigin/api/layers/zos-sprite/sprite@2x.png',
    ]);
    expect(b.version, '106b1f98a980');
    expect(b.etag, '"e1"');
    expect(b.tilesUrl, '$kZosOrigin/api/layers/zos-tiles');
    expect(b.spritePng, _png);

    // A new start (offline) gets the same bundle from the device.
    final kept = await store(MockClient((_) async => throw 'offline'))
        .cached(ZosTone.light);
    expect(kept!.version, '106b1f98a980');
    expect(kept.etag, '"e1"');
    expect(kept.spriteIndex.keys, contains('cave-red'));
    expect(await store(_vps([])).cached(ZosTone.dark), isNull);
  });

  test('an unchanged style is a 304, and the sprite is not fetched again',
      () async {
    final first = await store(_vps([])).refresh(ZosTone.light);
    final seen = <http.Request>[];
    final again = await store(_vps(seen)).refresh(ZosTone.light, current: first);
    expect(identical(again, first), isTrue);
    expect(seen.single.headers['if-none-match'], '"e1"');
  });

  test('the legend comes from the style metadata', () async {
    final b = await store(_vps([])).refresh(ZosTone.light);
    final n2k = b.legend['n2k']!;
    expect(n2k.map((r) => r.key), ['POV', 'POO']);
    expect(b.legend['nvj']!.single.key, isNull);
    expect(b.legend.keys.toSet(), {'mvo', 'epo', 'n2k', 'zo', 'nv', 'nvj'});
  });

  test('a VPS that cannot be reached is a ZosStyleException', () async {
    expect(store(MockClient((_) async => throw const SocketException('down')))
            .refresh(ZosTone.light),
        throwsA(isA<ZosStyleException>()));
    expect(store(_vps([], styleStatus: 502)).refresh(ZosTone.light),
        throwsA(isA<ZosStyleException>()));
  });

  test('a damaged copy on the device counts as none', () async {
    await Directory('${dir.path}/zos_style').create();
    for (final f in ['style-light.json', 'sprite-light.json']) {
      await File('${dir.path}/zos_style/$f').writeAsString('{not json');
    }
    await File('${dir.path}/zos_style/sprite-light.png').writeAsBytes(_png);
    expect(await store(_vps([])).cached(ZosTone.light), isNull);
  });

  test('the atlas holds the served icons and a dot per circle colour',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final b = ZosStyleBundle(
      tone: ZosTone.light,
      etag: null,
      style: (jsonDecode(utf8.decode(_style)) as Map).cast<String, dynamic>(),
      spriteIndex:
          (jsonDecode(utf8.decode(_index)) as Map).cast<String, dynamic>(),
      spritePng: _png,
    );
    final sprites = await zosSpriteStyle(b);
    final names = sprites.index.spriteByName.keys.toSet();
    expect(names, containsAll(['tri-drzavni', 'cave-red', 'pov-hatch-light']));
    expect(names.where((n) => n.startsWith('circle-')).length, 15);

    // The dot for a ZO narodni park is that class's green, at its centre.
    final codec = await ui.instantiateImageCodec(await sprites.atlasProvider());
    final atlas = (await codec.getNextFrame()).image;
    final bytes = (await atlas.toByteData())!;
    final dot = sprites.index.spriteByName['circle-zos-zo-pt-0']!;
    final at = ((dot.y + dot.height ~/ 2) * atlas.width + dot.x + dot.width ~/ 2) * 4;
    expect([bytes.getUint8(at), bytes.getUint8(at + 1), bytes.getUint8(at + 2)],
        [0x6C, 0xC0, 0x92]);
  });
}
