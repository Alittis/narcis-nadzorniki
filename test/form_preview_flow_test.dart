// TB-31: the form -> preview -> save round trip.
//
// The claim worth pinning is that "Uredi" returns to a form that is still
// filled in. It holds because the preview is pushed ON TOP of FormScreen, whose
// State keeps every field -- a pop restores it. Popping the form and re-pushing
// it would compile and look right until a warden hit Uredi and lost their work.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/form_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

/// Keeps `addRecord` off the filesystem. Without credentials `canSync` is
/// false, so it stays off the network too.
class _FakeStore extends LocalStore {
  final saves = <List<Disturbance>>[];

  @override
  Future<List<Disturbance>> load() async => [];

  @override
  Future<void> save(List<Disturbance> items) async => saves.add(items);
}

const _type = SelectedDisturbanceType(
  groupCode: 'G1',
  groupName: 'Vožnja v naravnem okolju',
  typeCode: 'T1',
  typeName: 'Vožnja z motornim vozilom',
);

Future<AppState> _openForm(WidgetTester tester, _FakeStore store) async {
  final state = AppState(localStore: store);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => const FormScreen(
                    initialLocation: LatLng(45.79, 14.36),
                    initialObservers: [],
                    mapCenter: LatLng(45.79, 14.36),
                    initialBasemap: BasemapMode.osm,
                    initialTypes: [_type],
                  ),
                ),
              ),
              child: const Text('domov'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('domov'));
  await tester.pumpAndSettle();
  return state;
}

/// Scrolls the form back to the description box. Necessary after a preview
/// round trip: `_tapPreview` leaves the ListView at the bottom, and the field is
/// then unbuilt, so a finder would report it missing rather than empty.
Future<void> _scrollToDescription(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(TextFormField),
    -300,
    scrollable: find.byType(Scrollable).first,
  );
}

/// The description box is the form's only TextFormField (the observer input is
/// a plain TextField and the "predlagaj nov tip" one is commented out), so no
/// key is needed to reach it.
Future<void> _describe(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextFormField), text);
  await tester.pump();
}

/// The action sits at the bottom of a long form. Scroll the form's own ListView
/// -- `.first` picks it out of the horizontal scrollers nested inside it.
Future<void> _tapPreview(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Preglej in shrani'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Preglej in shrani'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the form previews instead of committing', (tester) async {
    final store = _FakeStore();
    final state = await _openForm(tester, store);

    await _describe(tester, 'kolesar na zaprti poti');
    await _tapPreview(tester);

    expect(find.text('Predogled zapisa'), findsOneWidget);
    expect(find.text('kolesar na zaprti poti'), findsOneWidget);
    // Nothing has been committed by reaching the preview.
    expect(state.records, isEmpty);
    expect(store.saves, isEmpty);
  });

  testWidgets('Uredi comes back to a form that is still filled in',
      (tester) async {
    final store = _FakeStore();
    final state = await _openForm(tester, store);

    await _describe(tester, 'kolesar na zaprti poti');
    await _tapPreview(tester);
    await tester.tap(find.text('Uredi'));
    await tester.pumpAndSettle();

    expect(find.byType(DetailScreen), findsNothing);
    expect(find.byType(FormScreen), findsOneWidget);
    expect(state.records, isEmpty);

    await _scrollToDescription(tester);
    expect(find.text('kolesar na zaprti poti'), findsOneWidget);

    // ...and the corrected text is what gets saved.
    await _describe(tester, 'kolesar na zaprti poti, opozorjen');
    await _tapPreview(tester);
    expect(find.text('kolesar na zaprti poti, opozorjen'), findsOneWidget);
  });

  testWidgets('saving commits once and closes the form', (tester) async {
    final store = _FakeStore();
    final state = await _openForm(tester, store);

    await _describe(tester, 'kolesar na zaprti poti');
    await _tapPreview(tester);
    await tester.tap(find.text('Shrani zapis'));
    await tester.pumpAndSettle();

    expect(state.records, hasLength(1));
    expect(state.records.single.description, 'kolesar na zaprti poti');
    expect(state.records.single.types.single.typeCode, 'T1');

    // Both routes are gone: the preview popped, and the form popped with it.
    expect(find.byType(DetailScreen), findsNothing);
    expect(find.byType(FormScreen), findsNothing);
    expect(find.text('domov'), findsOneWidget);
  });
}
