// TB-30: the record list (Seznam zapisov) shows each record's case status after
// the observed date. Dot + label, sharing recordMarkerColorForStatus with the
// maps and the detail card so one status is one colour everywhere.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/screens/walk_detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

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

  // ---- TB-17: the obhod link ---------------------------------------------

  Walk walk({String? name}) => Walk(
        id: 'walk-1',
        startedAt: DateTime.utc(2026, 8, 20, 6, 30),
        endedAt: DateTime.utc(2026, 8, 20, 9, 0),
        pendingSync: false,
        name: name,
      );

  Future<void> pumpLink(WidgetTester tester, Walk? w) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ObhodLink(walk: w, dateFormat: DateFormat('dd.MM.yyyy HH:mm')),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a named walk shows its name', (tester) async {
    await pumpLink(tester, walk(name: 'Jutranji obhod'));
    expect(find.text('Jutranji obhod'), findsOneWidget);
  });

  testWidgets('an unnamed walk falls back to its LOCAL start time',
      (tester) async {
    await pumpLink(tester, walk());
    final expected = DateFormat('dd.MM.yyyy HH:mm')
        .format(DateTime.utc(2026, 8, 20, 6, 30).toLocal());
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('an empty name is treated as no name', (tester) async {
    await pumpLink(tester, walk(name: ''));
    expect(find.text(''), findsNothing);
    final expected = DateFormat('dd.MM.yyyy HH:mm')
        .format(DateTime.utc(2026, 8, 20, 6, 30).toLocal());
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('an unresolvable walk says so and is NOT tappable',
      (tester) async {
    // obhodId set but the walk is not in AppState.walks yet — a disturbance
    // logged during a walk carries the link before that walk reaches the
    // server. Offering a tap here would dead-end.
    await pumpLink(tester, null);
    expect(find.text('Del obhoda'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('tapping a resolved walk navigates to that walk', (tester) async {
    // Asserting the route push, not just that an InkWell exists — "tappable"
    // should mean it goes somewhere.
    final pushed = <Route<dynamic>>[];
    final observer = _RecordingObserver(pushed);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          navigatorObservers: [observer],
          home: Scaffold(
            body: ObhodLink(
              walk: walk(name: 'Jutranji obhod'),
              dateFormat: DateFormat('dd.MM.yyyy HH:mm'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    pushed.clear(); // drop the initial home route

    await tester.tap(find.text('Jutranji obhod'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // run the route transition

    expect(pushed, hasLength(1));
    expect(find.byType(WalkDetailScreen), findsOneWidget);
    // The destination's lazy point-fetch runs post-frame and has no server in
    // a widget test; drain whatever it threw so it cannot fail this test, which
    // is about navigation.
    tester.takeException();
  });

  testWidgets('walkLabel is the single source both screens use', (tester) async {
    final fmt = DateFormat('dd.MM.yyyy HH:mm');
    expect(walkLabel(walk(name: 'Popoldanski'), fmt), 'Popoldanski');
    expect(walkLabel(walk(name: ''), fmt),
        fmt.format(DateTime.utc(2026, 8, 20, 6, 30).toLocal()));
    expect(walkLabel(walk(), fmt),
        fmt.format(DateTime.utc(2026, 8, 20, 6, 30).toLocal()));
  });
}

class _RecordingObserver extends NavigatorObserver {
  _RecordingObserver(this.pushed);
  final List<Route<dynamic>> pushed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}
