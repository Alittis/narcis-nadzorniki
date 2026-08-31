// TB-30: the record list (Seznam zapisov) shows each record's case status after
// the observed date. Dot + label, sharing recordMarkerColorForStatus with the
// maps and the detail card so one status is one colour everywhere.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

Future<void> _pump(
  WidgetTester tester,
  String caseStatus, {
  double width = 411,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: ListTile(
              // the real tile's leading icon, so the layout under test matches
              leading: const Icon(Icons.check_circle),
              title: const Text('Ljudje izven poti'),
              subtitle: RecordStatusLine(
                date: '27.08.2026 09:08',
                caseStatus: caseStatus,
              ),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

List<BoxDecoration> _circles(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .where((d) => d.shape == BoxShape.circle)
    .toList();

void main() {
  testWidgets('shows the date and a labelled status', (tester) async {
    await _pump(tester, 'Zaključeno');
    expect(find.text('27.08.2026 09:08'), findsOneWidget);
    // labelled, not a bare colour — the defect that made TB-26 unreadable
    expect(find.text('Zaključeno'), findsOneWidget);
  });

  testWidgets('the dot uses the shared status palette', (tester) async {
    for (final status in allCaseStatuses) {
      await _pump(tester, status);
      expect(
        _circles(tester).map((d) => d.color),
        contains(recordMarkerColorForStatus(status)),
        reason: status,
      );
    }
  });

  testWidgets('every status in the vocabulary renders its label',
      (tester) async {
    for (final status in allCaseStatuses) {
      await _pump(tester, status);
      expect(find.text(status), findsOneWidget, reason: status);
    }
  });

  testWidgets('the longest status does not overflow, at any phone width',
      (tester) async {
    // 'Predano drugi službi' after a full dd.MM.yyyy HH:mm timestamp is the
    // worst case, and it DID overflow a 320 dp screen by 85 px as a Row. It
    // wraps to a second line now; these widths are the ones that caught it.
    for (final w in [320.0, 360.0, 411.0]) {
      await _pump(tester, 'Predano drugi službi', width: w);
      expect(tester.takeException(), isNull, reason: '$w dp');
      // findsOneWidget still holds under ellipsis — the Text widget is present
      // with its full string; only the painting is clipped.
      expect(find.text('Predano drugi službi'), findsOneWidget);
    }
  });

  testWidgets('an unknown status still renders, in the fallback gray',
      (tester) async {
    await _pump(tester, 'V mediaciji');
    expect(find.text('V mediaciji'), findsOneWidget);
    expect(
      _circles(tester).map((d) => d.color),
      contains(const Color(0xFF8E8E93)),
    );
  });
}
