// TB-4: the Karta picker opens on the record's own location.
//
// The form's location is the device fix taken when the warden tapped "+". The
// picker used to open on the home map's centre instead, so the red marker sat
// wherever the map happened to be scrolled, not on the blue dot. Each case runs
// through to the saved record, because that is what the warden is filing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/screens/form_screen.dart';
import 'package:narcis_nadzorniki/screens/location_picker_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

/// Keeps `addRecord` off the filesystem. Without credentials `canSync` is
/// false, so it stays off the network too.
class _FakeStore extends LocalStore {
  @override
  Future<List<Disturbance>> load() async => [];

  @override
  Future<void> save(List<Disturbance> items) async {}
}

const _type = SelectedDisturbanceType(
  groupCode: 'G1',
  groupName: 'Vožnja v naravnem okolju',
  typeCode: 'T1',
  typeName: 'Vožnja z motornim vozilom',
);

/// Where the warden stood at "+".
const _fix = LatLng(45.79, 14.36);

/// Where the home map was scrolled: several kilometres away.
const _mapCenter = LatLng(45.85, 14.50);

const _geolocator = MethodChannel('flutter.baseflow.com/geolocator');

Future<AppState> _openForm(WidgetTester tester, {LatLng? location}) async {
  final state = AppState(localStore: _FakeStore());
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => FormScreen(
                    initialLocation: location,
                    initialObservers: const [],
                    mapCenter: _mapCenter,
                    initialBasemap: BasemapMode.osm,
                    initialTypes: const [_type],
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

Future<void> _openPicker(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Karta'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Karta'));
  await tester.pumpAndSettle();
}

Future<void> _confirmPicker(WidgetTester tester) async {
  await tester.tap(find.text('Potrdi'));
  await tester.pumpAndSettle();
}

Future<Disturbance> _save(WidgetTester tester, AppState state) async {
  await tester.scrollUntilVisible(
    find.text('Preglej in shrani'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Preglej in shrani'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Shrani zapis'));
  await tester.pumpAndSettle();
  return state.records.single;
}

void main() {
  setUp(() {
    // No location service in the test host: the picker's own GPS read comes
    // back empty, as on a phone with location off.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_geolocator, (call) async {
      if (call.method == 'isLocationServiceEnabled') return false;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_geolocator, null);
  });

  testWidgets('the picker opens on the GPS fix, not the map centre',
      (tester) async {
    await _openForm(tester, location: _fix);
    await _openPicker(tester);

    final picker =
        tester.widget<LocationPickerScreen>(find.byType(LocationPickerScreen));
    expect(picker.initialLocation, _fix);
  });

  testWidgets('Potrdi without a tap keeps the fix and its accuracy',
      (tester) async {
    final state = await _openForm(tester, location: _fix);
    await _openPicker(tester);
    await _confirmPicker(tester);

    final record = await _save(tester, state);
    expect(LatLng(record.latitude, record.longitude), _fix);
    expect(record.locationAccuracy, 'Natančna');
  });

  testWidgets('a tap on the map moves the record and marks it Približna',
      (tester) async {
    final state = await _openForm(tester, location: _fix);
    await _openPicker(tester);
    await tester.tapAt(
      tester.getTopLeft(find.byType(FlutterMap)) + const Offset(40, 40),
    );
    // flutter_map holds a tap back for its double-tap window before onTap.
    await tester.pump(const Duration(milliseconds: 500));
    await _confirmPicker(tester);

    // A second visit opens on the pick, not back on the fix, so a fine-tune
    // is not lost; confirming it again keeps the pick.
    await _openPicker(tester);
    final pickedPoint = tester
        .widget<LocationPickerScreen>(find.byType(LocationPickerScreen))
        .initialLocation;
    expect(pickedPoint, isNot(_fix));
    await _confirmPicker(tester);

    final record = await _save(tester, state);
    expect(LatLng(record.latitude, record.longitude), pickedPoint);
    expect(record.locationAccuracy, 'Približna');
  });

  testWidgets('with no fix at all, the picker falls back to the map centre',
      (tester) async {
    final state = await _openForm(tester);
    await tester.scrollUntilVisible(
      find.text('Lokacija še ni nastavljena.'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // The form's own GPS attempt failed too; its snackbar covers the bottom of
    // the screen, where Karta lands after the scroll. Let it time out.
    expect(find.text('GPS lokacije ni mogoče pridobiti.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await _openPicker(tester);

    final picker =
        tester.widget<LocationPickerScreen>(find.byType(LocationPickerScreen));
    expect(picker.initialLocation, _mapCenter);

    // Confirming the centre is how a warden without GPS sets a location at all.
    await _confirmPicker(tester);
    final record = await _save(tester, state);
    expect(LatLng(record.latitude, record.longitude), _mapCenter);
    expect(record.locationAccuracy, 'Približna');
  });
}
