// Unit tests for zosSymbol — the mapping from an identified ObmocjeFeature to
// the colour + shape the NarcIS GeoServer actually renders on the map. Values
// mirror the SLD pulled from GetLegendGraphic (see obmocje_sheet.dart).

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart';

ObmocjeFeature _f(
  ZosKind kind, {
  bool point = false,
  String tip = '',
  String vrsta = '',
  String pomen = '',
  String status = '',
}) =>
    ObmocjeFeature(
      kind: kind,
      isPoint: point,
      ime: 'x',
      koda: 'k',
      tip: tip,
      vrsta: vrsta,
      pomen: pomen,
      status: status,
      opis: '',
      rows: const [],
    );

void main() {
  group('zosSymbol mirrors the GeoServer SLD', () {
    test('N2k POV is a red outline, POO an orange fill', () {
      final pov = zosSymbol(_f(ZosKind.n2k, tip: 'POV'));
      expect(pov.shape, ZosShape.polygonOutline);
      expect(pov.color, const Color(0xFFE30000));

      final poo = zosSymbol(_f(ZosKind.n2k, tip: 'POO'));
      expect(poo.shape, ZosShape.polygon);
      expect(poo.color, const Color(0xFFD98210));
    });

    test('ZO colour follows ZO_VRSTA; shape follows geometry', () {
      expect(zosSymbol(_f(ZosKind.zo, vrsta: 'naravni rezervat')).color,
          const Color(0xFFD01C8B));
      expect(zosSymbol(_f(ZosKind.zo, vrsta: 'regijski park')).shape,
          ZosShape.polygon);
      expect(
          zosSymbol(_f(ZosKind.zo, vrsta: 'naravni rezervat', point: true))
              .shape,
          ZosShape.circle);
      // Unknown vrsta falls back to the park green rather than throwing.
      expect(zosSymbol(_f(ZosKind.zo, vrsta: 'kaj pa vem')).color,
          const Color(0xFF6CC092));
    });

    test('NV points are triangles coloured by pomen; OP areas are outlines', () {
      expect(zosSymbol(_f(ZosKind.nv, point: true, pomen: 'lokalni')).color,
          const Color(0xFF178D89));
      expect(zosSymbol(_f(ZosKind.nv, point: true, pomen: 'državni')).shape,
          ZosShape.triangle);
      expect(zosSymbol(_f(ZosKind.nv)).shape, ZosShape.polygon);
      expect(zosSymbol(_f(ZosKind.nv, status: 'OP')).shape,
          ZosShape.polygonOutline);
    });

    test('EPO areas are pale-yellow polygons; jame use the cave glyph', () {
      expect(zosSymbol(_f(ZosKind.epo)).color, const Color(0xFFFBFB7F));
      expect(zosSymbol(_f(ZosKind.nvj, point: true)).shape, ZosShape.cave);
    });
  });
}
