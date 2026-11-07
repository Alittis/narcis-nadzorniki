// TB-28: a sign-in the server refuses after it succeeded at Račun NarcIS says
// why, and whom to ask. Since TB-46 the server tells the cases apart —
// `reason` not_authorized (no TERENSKA-BELEZNICA right) or no_org — so the hint
// follows the reason. Any other refusal (401, no reason) and the failures
// before the server (no signal, a cancelled browser) get no hint.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/screens/login_screen.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

class _FakeAppState extends AppState {
  _FakeAppState(this.result);
  final AuthResult result;

  @override
  Future<AuthResult> login({
    Future<bool> Function(String owner, String user, UnsentWork unsent)?
        confirmDiscard,
  }) async =>
      result;
}

Future<void> _submit(WidgetTester tester, AuthResult result) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: _FakeAppState(result),
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  // NV-554 P3: no fields any more; the button opens the browser.
  expect(find.byType(TextFormField), findsNothing);
  await tester.tap(find.text('Prijava z Računom NarcIS'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('not_authorized: the server says why, the hint says whom to ask',
      (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Prijava je uspela, vendar vaš račun nima pravice za '
            'Terensko beležnico (TERENSKA-BELEZNICA).',
        rejectedByServer: true,
        reason: 'not_authorized',
      ),
    );

    expect(find.textContaining('nima pravice'), findsOneWidget);
    expect(find.text(accessHintText), findsOneWidget);
    expect(accessHintText, contains('TERENSKA-BELEZNICA'));
    expect(accessHintText, contains('admin@alittis.com'));
  });

  testWidgets('no_org: its own hint', (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Prijava je uspela, vendar vaš račun ni povezan z nobeno '
            'organizacijo, zato zapisov ni mogoče shraniti.',
        rejectedByServer: true,
        reason: 'no_org',
      ),
    );

    expect(find.text(noOrgHintText), findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
    expect(noOrgHintText, contains('admin@alittis.com'));
  });

  testWidgets('a code the server refused: the generic error, no hint',
      (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Prijava ni uspela ali je potekla. Poskusite znova.',
        rejectedByServer: true,
      ),
    );

    expect(find.text('Prijava ni uspela ali je potekla. Poskusite znova.'),
        findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
    expect(find.text(noOrgHintText), findsNothing);
  });

  testWidgets('no signal shows the error but no hint', (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Za prijavo potrebujete internetno povezavo.',
      ),
    );

    expect(find.text('Za prijavo potrebujete internetno povezavo.'),
        findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
  });
}
