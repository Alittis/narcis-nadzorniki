// TB-26: the detail pane's case-review block.
//
// The first cut rendered reviewedBy and reviewedAt as two bare pills among the
// action pills — an e-mail and a date with nothing saying what they were. These
// tests pin the labelling, because that was the actual defect.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

Disturbance _rec({
  String caseStatus = 'Odprto',
  String? reviewedBy,
  DateTime? reviewedAt,
}) {
  return Disturbance(
    id: 'rec-1',
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: DateTime.utc(2026, 8, 20, 9),
    types: const [],
    description: 'opis',
    photos: const <DisturbancePhoto>[],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: caseStatus,
    pendingSync: false,
    createdAt: DateTime.utc(2026, 8, 20, 9),
    reviewedBy: reviewedBy,
    reviewedAt: reviewedAt,
  );
}

Future<void> _open(WidgetTester tester, Disturbance record) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(home: DetailScreen(record: record)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a reviewed record labels who and when', (tester) async {
    await _open(
      tester,
      _rec(
        caseStatus: 'Zaključeno',
        reviewedBy: 'referent@gov.si',
        reviewedAt: DateTime.utc(2026, 8, 26, 14, 30),
      ),
    );

    // the heading that gives the block its meaning
    expect(find.text('Obravnava'), findsOneWidget);
    // every value carries a label — this is the bug that prompted the card
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Obravnaval'), findsOneWidget);
    expect(find.text('Obravnavano'), findsOneWidget);

    expect(find.text('Zaključeno'), findsOneWidget);
    expect(find.text('referent@gov.si'), findsOneWidget);
    // Rendered in LOCAL time (TB-13). Computing the expectation the same way
    // the widget does keeps this TZ-independent, while still failing if the
    // widget ever drops its .toLocal() — on any host that is not UTC the two
    // strings differ by the offset.
    final expected = DateFormat('dd.MM.yyyy HH:mm')
        .format(DateTime.utc(2026, 8, 26, 14, 30).toLocal());
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('an unreviewed record says so instead of showing blanks',
      (tester) async {
    await _open(tester, _rec(caseStatus: 'Odprto'));

    expect(find.text('Obravnava'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Odprto'), findsOneWidget);
    expect(find.text('Zapis še ni bil obravnavan.'), findsOneWidget);
    // no empty labelled rows
    expect(find.text('Obravnaval'), findsNothing);
    expect(find.text('Obravnavano'), findsNothing);
  });

  testWidgets('the status appears once, in the Obravnava card', (tester) async {
    // It used to be a loose pill among the action pills as well; one place only.
    await _open(tester, _rec(caseStatus: 'V obravnavi'));
    expect(find.text('V obravnavi'), findsOneWidget);
  });
}
