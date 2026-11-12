// TB-37 added a seventh row to the Območja picker, and the default bottom sheet
// (at most 9/16 of the screen) overflowed by 3 px on the A56 (2026-11-12): the
// last row, Mednarodno varovana območja, was cut off. The sheet must fit every
// row on a phone, and stay usable on one too short for them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocja_picker.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart' show zosTitle;

Future<List<(ZosKind, bool)>> _open(WidgetTester tester, Size logical) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
  final changes = <(ZosKind, bool)>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showObmocjaPicker(
              context,
              active: {ZosKind.n2k},
              onChanged: (k, on) => changes.add((k, on)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return changes;
}

void main() {
  testWidgets('every row fits on the A56 (411 x 891 dp), without overflow',
      (tester) async {
    await _open(tester, const Size(411, 891));

    expect(tester.takeException(), isNull);
    final screen = tester.view.physicalSize.height;
    for (final k in zosOrder) {
      final row = find.text(zosTitle(k));
      expect(row, findsOneWidget);
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(screen),
          reason: '${k.name} is on screen');
    }
  });

  testWidgets('a short screen scrolls to the last row, which still toggles',
      (tester) async {
    final changes = await _open(tester, const Size(360, 480));

    expect(tester.takeException(), isNull);
    final last = find.text(zosTitle(zosOrder.last));
    await tester.scrollUntilVisible(last, 50,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(last);
    await tester.pump();

    expect(changes, [(zosOrder.last, true)]);
  });
}
