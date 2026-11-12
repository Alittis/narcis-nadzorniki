// TB-47: the style narcis-vibed serves (NV-546) is the web map's own; the
// phone converts the three things vector_tile_renderer 6.1.0 cannot draw.
//
// The drift guard's phone half: the converted style must go through the
// renderer's ThemeReader with NO warning and no layer lost, because the
// renderer skips what it cannot draw without an error. narcis-vibed's half
// (`web/scripts/verify-zos-style-phone.ts`) fails a served style that leaves
// the renderer's subset; this one catches that subset going stale.
//
// The fixtures are the live style of 2026-11-04. To check the live style:
//   ZOS_LIVE=1 flutter test test/zos_render_style_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/data/zos_render_style.dart';
import 'package:narcis_nadzorniki/data/zos_style_store.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

Map<String, dynamic> _fixture(String tone) =>
    (jsonDecode(File('test/fixtures/zos/style-$tone.json').readAsStringSync())
            as Map)
        .cast<String, dynamic>();

final _all = {for (final k in ZosKind.values) k.name};

class _Warnings implements vtr.Logger {
  final seen = <String>[];

  @override
  void log(String Function() message) {}

  @override
  void warn(String Function() message) => seen.add(message());
}

Map<String, dynamic> _layer(Map<String, dynamic> theme, String id) =>
    (theme['layers'] as List).cast<Map<String, dynamic>>().singleWhere(
          (l) => l['id'] == id,
        );

/// The guard itself: every converted layer reaches the renderer, silently.
void _expectRendererTakesAll(Map<String, dynamic> style, String label) {
  final converted = zosRenderStyle(style, _all);
  final log = _Warnings();
  final theme = vtr.ThemeReader(logger: log).read(converted.theme);
  expect(log.seen, isEmpty, reason: '$label: renderer warnings');
  expect(theme.layers.length, (converted.theme['layers'] as List).length,
      reason: '$label: layers the renderer dropped');
  expect(converted.dropped, ['zos-n2k-pov'],
      reason: '$label: only the POV hatch may be left out');
}

void main() {
  group('the drift guard (phone half)', () {
    for (final tone in ['light', 'dark']) {
      test('the $tone fixture goes through the renderer whole', () {
        _expectRendererTakesAll(_fixture(tone), tone);
      });
    }

    test(
      'the live style goes through the renderer whole',
      () async {
        for (final tone in ZosTone.values) {
          final res = await http.get(Uri.parse(
              '$kZosOrigin/api/layers/zos-style?tone=${tone.name}'));
          expect(res.statusCode, 200);
          _expectRendererTakesAll(
            (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
                .cast<String, dynamic>(),
            'live ${tone.name}',
          );
        }
      },
      skip: Platform.environment['ZOS_LIVE'] == '1'
          ? false
          : 'network; run with ZOS_LIVE=1',
    );
  });

  group('zosRenderStyle', () {
    final out = zosRenderStyle(_fixture('light'), _all);

    test('circle layers become symbol layers of dot sprites', () {
      final zo = _layer(out.theme, 'zos-zo-pt');
      expect(zo['type'], 'symbol');
      expect(zo['source-layer'], 'zo');
      expect(zo['filter'], ['==', ['geometry-type'], 'Point']);
      final icon = (zo['layout'] as Map)['icon-image'] as List;
      // The same match on _cls, with sprite names where the colours were.
      expect(icon.take(3), ['match', ['get', '_cls'], 'narodni-park']);
      expect(icon[3], startsWith('circle-zos-zo-pt-'));
      expect(zo['paint'], isNotNull);

      final dots = {for (final c in out.circles) c.name: c};
      final park = dots[icon[3]]!;
      expect(park.color, 0xFF6CC092);
      expect(park.radius, 5);
      expect(park.strokeColor, 0xFF646464);
      expect(park.strokeWidth, 1);
      // A dot for every output of the three circle layers' matches:
      // mvo 4 + fallback, n2k 1 + fallback, zo 7 + fallback.
      expect(out.circles.length, 5 + 2 + 8);
    });

    test('a literal circle colour becomes one sprite', () {
      final out = zosRenderStyle({
        'id': 't',
        'metadata': {'version': 'v'},
        'layers': [
          {
            'id': 'p',
            'type': 'circle',
            'source': 'zos',
            'source-layer': 'zo',
            'paint': {'circle-color': '#ff0000', 'circle-radius': 3},
          },
        ],
      }, {'zo'});
      expect(((out.theme['layers'] as List).single as Map)['layout'],
          {'icon-image': 'circle-p-0'});
      expect(out.circles.single.color, 0xFFFF0000);
      expect(out.circles.single.strokeWidth, 0); // MapLibre's default
    });

    test('a circle colour it cannot read drops the layer, not the style', () {
      final out = zosRenderStyle({
        'id': 't',
        'layers': [
          {
            'id': 'p',
            'type': 'circle',
            'source-layer': 'zo',
            'paint': {
              'circle-color': ['interpolate', ['linear'], ['zoom'], 5, '#f00']
            },
          },
          {'id': 'f', 'type': 'fill', 'source-layer': 'zo', 'paint': {}},
        ],
      }, {'zo'});
      expect(out.dropped, ['p']);
      expect((out.theme['layers'] as List).single['id'], 'f');
    });

    test('the POV hatch is dropped; POV keeps its outline', () {
      expect(out.dropped, ['zos-n2k-pov']);
      expect(_layer(out.theme, 'zos-n2k-line')['type'], 'line');
    });

    test('icon-only symbol layers get the paint block the renderer needs', () {
      expect(_layer(out.theme, 'zos-nvj-pt')['paint'], {'text-color': '#000000'});
      expect((_layer(out.theme, 'zos-nvj-pt')['layout'] as Map)['icon-image'],
          'cave-red');
    });

    test('only the active sublayers are kept, in the served order', () {
      final some = zosRenderStyle(_fixture('light'), {'nvj', 'n2k'});
      expect(
          (some.theme['layers'] as List).map((l) => l['id']),
          ['zos-n2k-fill', 'zos-n2k-line', 'zos-n2k-pt', 'zos-nvj-fill',
           'zos-nvj-line', 'zos-nvj-pt']);
    });

    test('the theme id names the active set; the version the revision', () {
      final some = zosRenderStyle(_fixture('light'), {'nvj', 'n2k'});
      expect(some.theme['id'], 'zos-light_n2k.nvj');
      expect((some.theme['metadata'] as Map)['version'],
          '106b1f98a980-r$kZosRendererRevision');
    });

    group('TB-37: natural monuments split out of ZO', () {
      List<Map<String, dynamic>> zoLayers(Set<String> active) =>
          (zosRenderStyle(_fixture('light'), active).theme['layers'] as List)
              .cast<Map<String, dynamic>>()
              .where((l) => l['source-layer'] == 'zo')
              .toList();
      const not = ['!=', ['get', '_cls'], kZoMonumentClass];
      const only = ['==', ['get', '_cls'], kZoMonumentClass];

      test('the slug is the kind', () {
        expect(ZosKind.ns.name, kZosMonumentSlug);
        expect(ZosKind.ns.sourceLayer, 'zo');
      });

      test('ZO alone leaves them out, on every ZO layer', () {
        final ls = zoLayers({'zo'});
        expect(ls.map((l) => l['id']),
            ['zos-zo-fill', 'zos-zo-line', 'zos-zo-pt']);
        expect(_layer({'layers': ls}, 'zos-zo-fill')['filter'], [
          'all', ['==', ['geometry-type'], 'Polygon'], not, //
        ]);
        expect(_layer({'layers': ls}, 'zos-zo-pt')['filter'], [
          'all', ['==', ['geometry-type'], 'Point'], not, //
        ]);
      });

      test('ns alone draws only them, from the ZO layers', () {
        final ls = zoLayers({'ns'});
        expect(ls, hasLength(3));
        expect(ls.every((l) => (l['filter'] as List).last.toString() ==
            only.toString()), isTrue);
      });

      test('both on: ZO as served', () {
        final served = (_fixture('light')['layers'] as List)
            .cast<Map<String, dynamic>>()
            .where((l) => l['source-layer'] == 'zo')
            .map((l) => l['filter'])
            .toList();
        expect(zoLayers({'zo', 'ns'}).map((l) => l['filter']).toList(), served);
      });

      test('each half has its own theme id, so its own tile cache', () {
        String id(Set<String> a) =>
            '${zosRenderStyle(_fixture('light'), a).theme['id']}';
        expect({id({'zo'}), id({'ns'}), id({'zo', 'ns'})}, hasLength(3));
      });

      for (final active in [
        {'zo'},
        {'ns'},
        {'n2k', 'ns', 'nv'},
      ]) {
        test('$active goes through the renderer whole', () {
          final converted = zosRenderStyle(_fixture('light'), active);
          final log = _Warnings();
          final theme = vtr.ThemeReader(logger: log).read(converted.theme);
          expect(log.seen, isEmpty);
          expect(theme.layers.length,
              (converted.theme['layers'] as List).length);
        });
      }
    });

    test('the served style is left as it came', () {
      final style = _fixture('light');
      final before = jsonEncode(style);
      zosRenderStyle(style, _all);
      expect(jsonEncode(style), before);
    });
  });

  group('parseZosColor', () {
    test('reads the forms the style uses', () {
      expect(parseZosColor('#D6161F'), 0xFFD6161F);
      expect(parseZosColor('#fff'), 0xFFFFFFFF);
      expect(parseZosColor('rgb(1, 2, 3)'), 0xFF010203);
      expect(parseZosColor('rgba(217,130,16,0.40)'), 0x66D98210);
    });

    test('anything else is null', () {
      for (final v in [null, 3, '', 'red', '#12345', 'rgba(1,2,3,2)', 'rgb(1,2)']) {
        expect(parseZosColor(v), isNull, reason: '$v');
      }
    });
  });
}
