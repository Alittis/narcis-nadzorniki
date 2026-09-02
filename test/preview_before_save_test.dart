// TB-31: the preview step between the form and the commit.
//
// Two things are pinned here. First, that the preview hides the blocks that are
// meaningless before a record exists (the sync badge would claim "queued to
// sync" for something the server has never seen; the obravnava card would say
// nothing has been reviewed, which is true of every unsaved record). Second --
// and this is the one that matters -- that a double-tap on save commits ONCE.
// That double-tap is the suspected source of TB-2's duplicate field records:
// onSave awaits the local write, the optimistic POST and the photo uploads, so
// it is live for seconds on a weak link.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

Disturbance _rec() {
  return Disturbance(
    id: 'rec-1',
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: DateTime.utc(2026, 9, 2, 9),
    types: const [],
    description: 'opis',
    photos: const <DisturbancePhoto>[],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: 'Odprto',
    // As the form builds it: never pushed, so the badge would be wrong.
    pendingSync: true,
    createdAt: DateTime.utc(2026, 9, 2, 9),
  );
}

/// Mounts the preview the way FormScreen does — pushed on top of another route,
/// so "Uredi" and the post-save pop have somewhere to land.
Future<void> _openPreview(
  WidgetTester tester, {
  required Future<void> Function() onSave,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => DetailScreen(
                    record: _rec(),
                    preview: true,
                    onSave: onSave,
                  ),
                ),
              ),
              child: const Text('obrazec'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('obrazec'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the preview offers both exits and hides the unsaved-record noise',
      (tester) async {
    await _openPreview(tester, onSave: () async {});

    expect(find.text('Predogled zapisa'), findsOneWidget);
    expect(find.text('Uredi'), findsOneWidget);
    expect(find.text('Shrani zapis'), findsOneWidget);
    // The record's own content is what the warden is here to check.
    expect(find.text('opis'), findsOneWidget);

    expect(find.text('Obravnava'), findsNothing);
    expect(find.byTooltip('V čakanju na sinhronizacijo'), findsNothing);
  });

  testWidgets('the action bar fits a narrow phone', (tester) async {
    // The default 800x600 test surface is wider than any phone the wardens
    // carry, and a two-button row is exactly the shape that overflows. A
    // RenderFlex overflow fails this test rather than printing a stripe nobody
    // reads.
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _openPreview(tester, onSave: () async {});

    expect(find.text('Uredi'), findsOneWidget);
    expect(find.text('Shrani zapis'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the normal detail view is untouched', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(home: DetailScreen(record: _rec())),
      ),
    );
    await tester.pump();

    expect(find.text('Podrobnosti zapisa'), findsOneWidget);
    expect(find.text('Obravnava'), findsOneWidget);
    expect(find.byTooltip('V čakanju na sinhronizacijo'), findsOneWidget);
    expect(find.text('Shrani zapis'), findsNothing);
    expect(find.text('Uredi'), findsNothing);
  });

  testWidgets('a double-tap on save commits exactly once', (tester) async {
    final gate = Completer<void>();
    var calls = 0;

    await _openPreview(tester, onSave: () {
      calls++;
      return gate.future;
    });

    // Twice with no pump in between: both taps reach the same live onPressed,
    // exactly as a real double-tap does. Only the _saving guard stops the
    // second one -- the rebuild that disables the button hasn't happened yet.
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);

    // While the push is in flight the button says so and refuses further taps.
    expect(find.text('Shranjujem...'), findsOneWidget);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);

    gate.complete();
    await tester.pumpAndSettle();

    // Saved: the preview popped. (Popping the form itself is FormScreen's job,
    // driven by the `true` this route returns.)
    expect(find.byType(DetailScreen), findsNothing);
  });

  testWidgets('Uredi returns without committing', (tester) async {
    var calls = 0;
    await _openPreview(tester, onSave: () async => calls++);

    await tester.tap(find.text('Uredi'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byType(DetailScreen), findsNothing);
    expect(find.text('obrazec'), findsOneWidget);
  });
}
