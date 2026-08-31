import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/widgets/motnje_filter_sheet.dart';

SelectedDisturbanceType _type(String groupCode, String groupName) =>
    SelectedDisturbanceType(
      groupCode: groupCode,
      groupName: groupName,
      typeCode: 'a',
      typeName: 'x',
    );

Disturbance _rec({
  required DateTime observedAt,
  String? createdBy,
  List<SelectedDisturbanceType> types = const [],
}) {
  return Disturbance(
    id: 'id-${observedAt.microsecondsSinceEpoch}-${createdBy ?? 'me'}',
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: observedAt,
    types: types,
    description: '',
    photos: const [],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: 'Odprto',
    pendingSync: false,
    createdAt: observedAt,
    createdBy: createdBy,
  );
}

Future<void> _open(
  WidgetTester tester, {
  required List<Disturbance> records,
  required void Function(MotnjeFilter) onChanged,
  String? me = 'me@gov.si',
  MotnjeFilter initial = const MotnjeFilter.unfiltered(),
  bool showMotnje = true,
  void Function(bool)? onShowChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showMotnjeFilterSheet(
            context,
            showMotnje: showMotnje,
            onShowChanged: onShowChanged ?? (_) {},
            filter: initial,
            records: records,
            currentUserEmail: me,
            onChanged: onChanged,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final now = DateTime.now();
  List<Disturbance> sampleRecords() => [
        _rec(observedAt: now.subtract(const Duration(days: 5)), createdBy: 'me@gov.si'),
        _rec(observedAt: now.subtract(const Duration(days: 200)), createdBy: 'ana@gov.si'),
        _rec(observedAt: now.subtract(const Duration(days: 500)), createdBy: 'ana@gov.si'),
      ];

  testWidgets('the Starost section is gone (TB-29)', (tester) async {
    // Removed with the age colouring it existed to mirror; Obdobje covers date
    // filtering with a day-granularity range instead of three coarse buckets.
    await _open(tester, records: sampleRecords(), onChanged: (_) {});
    expect(find.text('Starost'), findsNothing);
    expect(find.text('Zadnji mesec'), findsNothing);
    expect(find.text('Zadnje leto'), findsNothing);
    expect(find.text('Starejše'), findsNothing);
    // and the dimension it fed is unfiltered by default
    expect(const MotnjeFilter.unfiltered().isActive, isFalse);
  });

  testWidgets('the author section is single-select and emits one author',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    // Two distinct authors → the Avtor section renders (me + ana).
    expect(find.text('Avtor'), findsOneWidget);
    await tester.ensureVisible(find.text('ana'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ana'));
    await tester.pump();

    expect(emitted.last.authors, {'ana@gov.si'});
    expect(emitted.last.isActive, isTrue);
  });

  testWidgets('Ponastavi clears every dimension back to unfiltered',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    await tester.ensureVisible(find.text('Zaključeno'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zaključeno')); // narrow → enables Ponastavi
    await tester.pump();
    expect(emitted.last.isActive, isTrue); // guard: the narrowing actually landed

    await tester.ensureVisible(find.text('Ponastavi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ponastavi'));
    await tester.pump();

    expect(emitted.last.isActive, isFalse);
    expect(emitted.last.statuses, allCaseStatuses);
    expect(emitted.last.authors, isEmpty);
  });

  testWidgets('author section is hidden when all records share one author',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(
      tester,
      records: [
        _rec(observedAt: now.subtract(const Duration(days: 5)), createdBy: 'me@gov.si'),
        _rec(observedAt: now.subtract(const Duration(days: 9)), createdBy: 'me@gov.si'),
      ],
      onChanged: emitted.add,
    );

    expect(find.text('Avtor'), findsNothing);
    expect(find.text('Status obravnave'), findsOneWidget);
  });

  testWidgets('category section narrows by group when >1 category present',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    final recs = [
      _rec(
        observedAt: now.subtract(const Duration(days: 5)),
        createdBy: 'me@gov.si',
        types: [_type('1', 'Sprehajalci')],
      ),
      _rec(
        observedAt: now.subtract(const Duration(days: 9)),
        createdBy: 'me@gov.si',
        types: [_type('4', 'Vožnja')],
      ),
    ];
    await _open(tester, records: recs, onChanged: emitted.add);

    expect(find.text('Kategorija'), findsOneWidget);
    await tester.ensureVisible(find.text('Kategorija'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kategorija')); // expand the section
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Vožnja')); // may sit below the fold
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vožnja')); // uncheck → narrows to the rest
    await tester.pump();

    expect(emitted.last.groups, {'1'});
    expect(emitted.last.isActive, isTrue);
  });

  testWidgets('master switch toggles layer visibility via onShowChanged',
      (tester) async {
    bool? shown;
    await _open(
      tester,
      records: sampleRecords(),
      onChanged: (_) {},
      showMotnje: true,
      onShowChanged: (v) => shown = v,
    );

    await tester.tap(find.text('Prikaži na zemljevidu'));
    await tester.pump();

    expect(shown, isFalse);
  });

  testWidgets('the Status section renders the map legend and narrows on tap',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    // TB-27: this section is the only key the warden has to the dot colours, so
    // all four states render even though every sample record is 'Odprto'.
    expect(find.text('Status obravnave'), findsOneWidget);
    for (final status in allCaseStatuses) {
      expect(find.text(status), findsOneWidget, reason: status);
    }

    await tester.ensureVisible(find.text('Zaključeno'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zaključeno'));
    await tester.pump();

    expect(emitted.last.statuses, isNot(contains('Zaključeno')));
    expect(emitted.last.statuses, contains('Odprto'));
    expect(emitted.last.isActive, isTrue);
  });

  testWidgets('Ponastavi restores every status', (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    await tester.ensureVisible(find.text('Odprto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odprto'));
    await tester.pump();
    expect(emitted.last.isActive, isTrue);

    await tester.ensureVisible(find.text('Ponastavi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ponastavi'));
    await tester.pump();

    expect(emitted.last.statuses, allCaseStatuses);
    expect(emitted.last.isActive, isFalse);
  });
}
