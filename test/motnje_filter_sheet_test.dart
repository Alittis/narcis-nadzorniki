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
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showMotnjeFilterSheet(
            context,
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

  testWidgets('unchecking an age bucket emits a narrowed, active filter',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    await tester.tap(find.text('Starejše'));
    await tester.pump();

    expect(emitted.last.ageBuckets, {AgeBucket.recent, AgeBucket.mid});
    expect(emitted.last.isActive, isTrue);
  });

  testWidgets('the author section is single-select and emits one author',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    // Two distinct authors → the Avtor section renders (me + ana).
    expect(find.text('Avtor'), findsOneWidget);
    await tester.tap(find.text('ana'));
    await tester.pump();

    expect(emitted.last.authors, {'ana@gov.si'});
    expect(emitted.last.isActive, isTrue);
  });

  testWidgets('Ponastavi clears every dimension back to unfiltered',
      (tester) async {
    final emitted = <MotnjeFilter>[];
    await _open(tester, records: sampleRecords(), onChanged: emitted.add);

    await tester.tap(find.text('Starejše')); // narrow → enables Ponastavi
    await tester.pump();
    await tester.tap(find.text('Ponastavi'));
    await tester.pump();

    expect(emitted.last.isActive, isFalse);
    expect(emitted.last.ageBuckets.length, allAgeBuckets.length);
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
    expect(find.text('Starost'), findsOneWidget);
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
    await tester.tap(find.text('Kategorija')); // expand the section
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vožnja')); // uncheck → narrows to the rest
    await tester.pump();

    expect(emitted.last.groups, {'1'});
    expect(emitted.last.isActive, isTrue);
  });
}
