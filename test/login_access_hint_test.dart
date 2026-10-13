// TB-28: the server's 401 says "Neveljavni podatki za prijavo." both for a
// wrong password and for an account without the TERENSKA-BELEZNICA right, so
// after that answer the login screen also says the right is needed and whom to
// ask. Other failures (offline, a refused TB-48 login) never reached the
// server's check and get no hint.

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
  testWidgets('a server 401 shows the hint under the error', (tester) async {
    await _submit(
      tester,
      const AuthResult(
        success: false,
        message: 'Neveljavni podatki za prijavo.',
        rejectedByServer: true,
      ),
    );

    expect(find.text('Neveljavni podatki za prijavo.'), findsOneWidget);
    expect(find.text(accessHintText), findsOneWidget);
    expect(accessHintText, contains('TERENSKA-BELEZNICA'));
    expect(accessHintText, contains('admin@alittis.com'));
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
