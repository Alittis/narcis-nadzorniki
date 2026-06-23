import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/screens/type_selection_screen.dart';

void main() {
  testWidgets('empty query shows the grouped browse view', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: TypeSelectionScreen(initialSelections: []),
    ));

    // Group titles from the codebook are visible (ExpansionTile titles).
    expect(find.text('Sprehajalci'), findsOneWidget);
    expect(find.text('Kopalci'), findsOneWidget);
  });

  testWidgets('typing filters to a flat results list', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: TypeSelectionScreen(initialSelections: []),
    ));

    await tester.enterText(find.byType(TextField), 'sneman');
    await tester.pumpAndSettle();

    // Matching types are shown...
    expect(find.textContaining('Snemanje'), findsWidgets);
    // ...and a non-matching group has dropped out of the list.
    expect(find.text('Sprehajalci'), findsNothing);
  });

  testWidgets('no match shows the empty-results message', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: TypeSelectionScreen(initialSelections: []),
    ));

    await tester.enterText(find.byType(TextField), 'zzqxwk');
    await tester.pumpAndSettle();

    expect(find.textContaining('Ni zadetkov'), findsOneWidget);
  });

  testWidgets('Končaj button reflects the selection count', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: TypeSelectionScreen(
        initialSelections: [
          SelectedDisturbanceType(
            groupCode: '1',
            groupName: 'Sprehajalci',
            typeCode: 'a',
            typeName: 'Ljudje izven poti',
          ),
        ],
      ),
    ));

    expect(find.text('Končaj (1)'), findsOneWidget);
  });
}
