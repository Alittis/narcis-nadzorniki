import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

/// Shown under the server's message when it refused a sign-in for a
/// missing TERENSKA-BELEZNICA right (TB-28; reason `not_authorized` since
/// TB-46). Names the publisher, who provisions closed-test accounts; at
/// production scale the addressee becomes the organisation's administrator —
/// change this, [noOrgHintText] and both PLAY_CLOSED_TEST invite templates
/// together.
const accessHintText =
    'Registracija v NarcIS ni dovolj: potrebna je tudi pravica '
    'TERENSKA-BELEZNICA. Za dodelitev pišite na admin@alittis.com.';

/// The same, for an account with no organisation (reason `no_org`, TB-46):
/// every record is stored under its author's organisation.
const noOrgHintText =
    'Račun mora biti v NarcIS povezan z organizacijo. Za ureditev pišite na '
    'admin@alittis.com.';

/// The hint for a server refusal's [reason]; null for any other refusal
/// (TB-28 half 2).
String? hintForReason(String? reason) => switch (reason) {
  'not_authorized' => accessHintText,
  'no_org' => noOrgHintText,
  _ => null,
};

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _submitting = false;
  String? _error;
  String? _hint;

  /// NV-554 P3: the sign-in happens at Račun NarcIS in the phone's browser.
  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
      _hint = null;
    });
    final result = await context.read<AppState>().login(
      confirmDiscard: (owner, user, unsent) async {
        if (!mounted) return false;
        return showForeignUnsentDialog(
          context,
          owner: owner,
          user: user,
          unsent: unsent,
        );
      },
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = result.success ? null : (result.message ?? 'Prijava ni uspela.');
      _hint = !result.success && result.rejectedByServer
          ? hintForReason(result.reason)
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    const shadow = [
      Shadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 1)),
    ];
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
                              shadows: shadow,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Prijavite se z Računom NarcIS. Odprl se bo '
                          'brskalnik: vnesite e-naslov in geslo (skrbniki tudi '
                          'kodo za prijavo v dveh korakih) in dovolite dostop '
                          'aplikaciji. Za prijavo potrebujete internetno '
                          'povezavo; prijavljeni ostanete tudi brez nje.',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.shade900.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      // TB-28: whom to ask, when the server said why a
                      // successful sign-in was refused.
                      if (_hint != null) ...[
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
                          child: Text(
                            _hint!,
                            style: const TextStyle(
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
                            : const Text('Prijava z Računom NarcIS'),
                      ),
                    ],
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
          Text(
            'Na tej napravi so podatki uporabnika $owner, ki jih strežnik '
            'še nima:',
          ),
          const SizedBox(height: 8),
          if (unsent.records > 0) Text('• zapisi: ${unsent.records}'),
          if (unsent.walks > 0) Text('• obhodi: ${unsent.walks}'),
          if (unsent.deletes > 0) Text('• izbrisi: ${unsent.deletes}'),
          if (unsent.activeWalk) const Text('• obhod, ki se še snema'),
          const SizedBox(height: 12),
          Text(
            'Pošlje jih lahko le ta uporabnik, ko se prijavi. Če nadaljujete '
            'kot $user, bodo izgubljeni.',
          ),
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
