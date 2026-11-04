// TB-47: the identify sheet's swatch shows a feature the way the map draws it.
// The colour is the served legend's (resolved into ObmocjeFeature.color by the
// identify); the shape follows how the web style draws that kind of feature.

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart';

ObmocjeFeature _f(
  ZosKind kind, {
  bool point = false,
  String cls = '',
  int? color = 0xFF123456,
}) =>
    ObmocjeFeature(
      kind: kind,
      id: 1,
      isPoint: point,
      ime: 'x',
      koda: 'k',
      cls: cls,
      color: color,
      opis: '',
      rows: const [],
    );

void main() {
  group('zosSymbol', () {
    test('the colour is the legend colour the feature carries', () {
      expect(zosSymbol(_f(ZosKind.zo)).color, const Color(0xFF123456));
    });

    test('no legend colour draws grey rather than failing', () {
      expect(zosSymbol(_f(ZosKind.zo, color: null)).color,
          const Color(0xFF8E8E93));
    });

    test('Natura 2000 POV is an outline (the hatch the phone cannot draw)', () {
      expect(zosSymbol(_f(ZosKind.n2k, cls: 'POV')).shape,
          ZosShape.polygonOutline);
      expect(zosSymbol(_f(ZosKind.n2k, cls: 'POO')).shape, ZosShape.polygon);
    });

    test('areas of the other layers are filled', () {
      for (final k in [
        ZosKind.zo,
        ZosKind.epo,
        ZosKind.nv,
        ZosKind.nvj,
        ZosKind.mvo,
      ]) {
        expect(zosSymbol(_f(k)).shape, ZosShape.polygon, reason: k.name);
      }
    });

    test('points take their layer mark: dot, triangle or cave', () {
      expect(zosSymbol(_f(ZosKind.n2k, point: true)).shape, ZosShape.circle);
      expect(zosSymbol(_f(ZosKind.zo, point: true)).shape, ZosShape.circle);
      expect(zosSymbol(_f(ZosKind.mvo, point: true)).shape, ZosShape.circle);
      expect(zosSymbol(_f(ZosKind.nv, point: true)).shape, ZosShape.triangle);
      expect(zosSymbol(_f(ZosKind.nvj, point: true)).shape, ZosShape.cave);
      expect(zosSymbol(_f(ZosKind.epo, point: true)).shape, ZosShape.cave);
    });
  });

  test('every sublayer has a picker title and a short label', () {
    for (final k in ZosKind.values) {
      expect(zosTitle(k), isNotEmpty);
      expect(zosShort(k), isNotEmpty);
    }
  });
}
