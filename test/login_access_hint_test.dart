// TB-28: a login refused with the right password says why, and whom to ask.
// Since TB-46 the server tells the cases apart — `reason` not_authorized (no
// TERENSKA-BELEZNICA right) or no_org — so the hint follows the reason. A
// wrong password (401, no reason) and the offline failures get no hint.

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
  Future<AuthResult> login(
    String email,
    String password, {
    Future<bool> Function(String owner, UnsentWork unsent)? confirmDiscard,
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
  await tester.enterText(find.byType(TextFormField).at(0), 'ana@gov.si');
  await tester.enterText(find.byType(TextFormField).at(1), 'geslo');
  await tester.tap(find.text('Prijava'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('not_authorized: the server says why, the hint says whom to ask',
      (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Geslo je pravilno, vendar vaš račun nima pravice za '
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
        message: 'Geslo je pravilno, vendar vaš račun ni povezan z nobeno '
            'organizacijo, zato zapisov ni mogoče shraniti.',
        rejectedByServer: true,
        reason: 'no_org',
      ),
    );

    expect(find.text(noOrgHintText), findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
    expect(noOrgHintText, contains('admin@alittis.com'));
  });

  testWidgets('a wrong password: the generic error, no hint', (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Neveljavni podatki za prijavo.',
        rejectedByServer: true,
      ),
    );

    expect(find.text('Neveljavni podatki za prijavo.'), findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
    expect(find.text(noOrgHintText), findsNothing);
  });

  testWidgets('an offline failure shows the error but no hint',
      (tester) async {
    await _submit(
      tester,
      const AuthResult(success: false, message: 'Brez povezave: napačno geslo.'),
    );

    expect(find.text('Brez povezave: napačno geslo.'), findsOneWidget);
    expect(find.text(accessHintText), findsNothing);
  });
}
