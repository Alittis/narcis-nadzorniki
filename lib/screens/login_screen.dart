import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

/// Shown under the error after the server rejects a login (TB-28). Names the
/// publisher, who provisions closed-test accounts; at production scale the
/// addressee becomes the organisation's administrator.
const accessHintText =
    'Če je geslo pravilno, vaš račun morda nima pravice za Terensko '
    'beležnico. Registracija v NarcIS ni dovolj: potrebna je tudi pravica '
    'TERENSKA-BELEZNICA. Za dodelitev pišite na admin@alittis.com.';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;
  bool _accessHint = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _accessHint = false;
    });
    final result = await context.read<AppState>().login(
      _emailController.text,
      _passwordController.text,
      confirmDiscard: (owner, unsent) async {
        if (!mounted) return false;
        return showForeignUnsentDialog(
          context,
          owner: owner,
          user: _emailController.text.trim(),
          unsent: unsent,
        );
      },
    );
    if (result.success) {
      TextInput.finishAutofillContext();
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = result.success ? null : (result.message ?? 'Prijava ni uspela.');
      _accessHint = !result.success && result.rejectedByServer;
    });
  }

  InputDecoration _fieldDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.78),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      errorStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
        shadows: [
          Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/login_bg.jpg',
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                const ColoredBox(color: Color(0xFF2E7D32)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.45),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _formKey,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Terenska beležnica',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black54,
                                      blurRadius: 6,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          TextFormField(
                            controller: _emailController,
                            autofillHints: const [
                              AutofillHints.username,
                              AutofillHints.email,
                            ],
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: _fieldDecoration(
                              hint: 'E-pošta',
                              icon: Icons.person_outline,
                            ),
                            validator: (value) {
                              final v = value?.trim() ?? '';
                              if (v.isEmpty) return 'Vnesite e-pošto.';
                              if (!v.contains('@'))
                                return 'Neveljaven e-poštni naslov.';
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordController,
                            autofillHints: const [AutofillHints.password],
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            decoration: _fieldDecoration(
                              hint: 'Geslo',
                              icon: Icons.lock_outline,
                            ),
                            validator: (value) {
                              if ((value ?? '').isEmpty)
                                return 'Vnesite geslo.';
                              return null;
                            },
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red.shade900.withValues(
                                  alpha: 0.82,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                          // TB-28: the server's 401 reads the same for a
                          // wrong password and a missing app right.
                          if (_accessHint) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                accessHintText,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Prijava'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TB-48: the device holds work another account captured and the server does
/// not have. Returns true only for *Zavrzi in nadaljuj*; *Prekliči* and a tap
/// outside both keep the work and refuse the login.
Future<bool> showForeignUnsentDialog(
  BuildContext context, {
  required String owner,
  required String user,
  required UnsentWork unsent,
}) async {
  final colors = Theme.of(context).colorScheme;
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Neposlani podatki drugega uporabnika'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Na tej napravi so podatki uporabnika $owner, ki jih strežnik '
              'še nima:'),
          const SizedBox(height: 8),
          if (unsent.records > 0) Text('• zapisi: ${unsent.records}'),
          if (unsent.walks > 0) Text('• obhodi: ${unsent.walks}'),
          if (unsent.deletes > 0) Text('• izbrisi: ${unsent.deletes}'),
          if (unsent.activeWalk) const Text('• obhod, ki se še snema'),
          const SizedBox(height: 12),
          Text('Pošlje jih lahko le ta uporabnik, ko se prijavi. Če nadaljujete '
              'kot $user, bodo izgubljeni.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Prekliči'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Zavrzi in nadaljuj'),
        ),
      ],
    ),
  );
  return discard == true;
}
