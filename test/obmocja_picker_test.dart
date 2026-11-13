// TB-37 added a seventh row to the Območja picker, and the default bottom sheet
// (at most 9/16 of the screen) overflowed by 3 px on the A56 (2026-11-12): the
// last row, Mednarodno varovana območja, was cut off. The sheet must fit every
// row on a phone, and stay usable on one too short for them.
//
// TB-60 made Zavarovana območja a parent row over Naravni spomeniki and the
// rest of ZO (2026-11-13): ticking ZO alone had hidden its natural monuments.
// The parent turns both halves on or off together; each half still toggles
// alone, and the parent shows "some" when only one is on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocja_picker.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart' show zosTitle;

const _group = 'Zavarovana območja';
final _ns = zosTitle(ZosKind.ns);
final _rest = zosTitle(ZosKind.zo);

Future<List<Set<ZosKind>>> _open(
  WidgetTester tester, {
  Size logical = const Size(411, 891), // the A56
  Set<ZosKind> active = const {ZosKind.n2k},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
  final changes = <Set<ZosKind>>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showObmocjaPicker(
              context,
              active: active,
              onChanged: changes.add,
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

bool? _checked(WidgetTester tester, String title) => tester
    .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, title))
    .value;

void main() {
  testWidgets('every row fits on the A56 (411 x 891 dp), without overflow',
      (tester) async {
    await _open(tester);

    expect(tester.takeException(), isNull);
    final screen = tester.view.physicalSize.height;
    for (final title in [_group, for (final k in zosOrder) zosTitle(k)]) {
      final row = find.text(title);
      expect(row, findsOneWidget, reason: title);
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(screen),
          reason: '$title is on screen');
    }
  });

  testWidgets('a short screen scrolls to the last row, which still toggles',
      (tester) async {
    final changes = await _open(tester, logical: const Size(360, 480));

    expect(tester.takeException(), isNull);
    final last = find.text(zosTitle(zosOrder.last));
    await tester.scrollUntilVisible(last, 50,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(last);
    await tester.pump();

    expect(changes, [
      {ZosKind.n2k, zosOrder.last}
    ]);
  });

  testWidgets('both halves sit indented right under the parent row',
      (tester) async {
    await _open(tester);

    final group = tester.getTopLeft(find.text(_group));
    final ns = tester.getTopLeft(find.text(_ns));
    final rest = tester.getTopLeft(find.text(_rest));
    final next = tester.getTopLeft(find.text(zosTitle(ZosKind.epo)));
    expect(ns.dx, greaterThan(group.dx));
    expect(rest.dx, ns.dx);
    expect(group.dy, lessThan(ns.dy));
    expect(ns.dy, lessThan(rest.dy));
    expect(rest.dy, lessThan(next.dy));
  });

  testWidgets('ticking the parent turns ZO on with its natural monuments',
      (tester) async {
    final changes = await _open(tester);
    expect(_checked(tester, _group), isFalse);

    await tester.tap(find.text(_group));
    await tester.pump();

    expect(changes, [
      {ZosKind.n2k, ZosKind.zo, ZosKind.ns}
    ]);
    expect(_checked(tester, _group), isTrue);
    expect(_checked(tester, _ns), isTrue);
    expect(_checked(tester, _rest), isTrue);
  });

  testWidgets('with one half on, the parent shows "some" and a tap adds the other',
      (tester) async {
    final changes = await _open(tester, active: {ZosKind.n2k, ZosKind.zo});
    expect(_checked(tester, _group), isNull);

    await tester.tap(find.text(_group));
    await tester.pump();

    expect(changes, [
      {ZosKind.n2k, ZosKind.zo, ZosKind.ns}
    ]);
    expect(_checked(tester, _group), isTrue);
  });

  testWidgets('with both halves on, the parent turns both off',
      (tester) async {
    final changes =
        await _open(tester, active: {ZosKind.n2k, ZosKind.zo, ZosKind.ns});
    expect(_checked(tester, _group), isTrue);

    await tester.tap(find.text(_group));
    await tester.pump();

    expect(changes, [
      {ZosKind.n2k}
    ]);
    expect(_checked(tester, _ns), isFalse);
    expect(_checked(tester, _rest), isFalse);
  });

  testWidgets('a half toggles alone, and the parent follows', (tester) async {
    final changes = await _open(tester, active: {ZosKind.zo, ZosKind.ns});

    await tester.tap(find.text(_ns));
    await tester.pump();
    expect(changes.last, {ZosKind.zo});
    expect(_checked(tester, _group), isNull);

    await tester.tap(find.text(_rest));
    await tester.pump();
    expect(changes.last, <ZosKind>{});
    expect(_checked(tester, _group), isFalse);
  });
}
