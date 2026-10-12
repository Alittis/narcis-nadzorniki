import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

/// The *Odjava* row on the Profil screen (TB-45).
///
/// `AppState.logout()` wipes the local stores so the next user of the device
/// does not see the previous user's data — and that used to take records and
/// walks the server had never received with it, silently. This row sends what
/// it can first, and asks only when something would still be lost.
class LogoutTile extends StatefulWidget {
  const LogoutTile({super.key, required this.email, required this.onLogout});

  final String email;

  /// Runs the actual logout once nothing is at stake, or the user has agreed
  /// to discard what is.
  final Future<void> Function() onLogout;

  @override
  State<LogoutTile> createState() => _LogoutTileState();
}

class _LogoutTileState extends State<LogoutTile> {
  /// Disables the row while the send runs, so a second tap cannot start a
  /// second flow (`syncAll` would return early and the dialog would appear
  /// while the first send is still going).
  bool _sending = false;

  Future<void> _logout() async {
    final state = context.read<AppState>();
    setState(() => _sending = true);
    final unsent = await state.sendUnsentBeforeLogout();
    if (!mounted) return;
    setState(() => _sending = false);
    if (!unsent.isEmpty && !await showUnsentWorkDialog(context, unsent)) {
      return;
    }
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.logout),
      title: const Text('Odjava'),
      subtitle: Text(_sending ? 'Pošiljam neposlane podatke…' : widget.email),
      trailing: _sending
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      enabled: !_sending,
      onTap: _logout,
    );
  }
}

/// Says what a logout would discard. Returns true only when the user chooses
/// *Odjavi in zavrzi*; *Prekliči* and a tap outside both keep the data.
Future<bool> showUnsentWorkDialog(
  BuildContext context,
  UnsentWork unsent,
) async {
  final colors = Theme.of(context).colorScheme;
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Neposlani podatki'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Strežnik teh podatkov s te naprave še nima:'),
          const SizedBox(height: 8),
          if (unsent.records > 0) Text('• zapisi: ${unsent.records}'),
          if (unsent.walks > 0) Text('• obhodi: ${unsent.walks}'),
          if (unsent.deletes > 0) Text('• izbrisi: ${unsent.deletes}'),
          if (unsent.activeWalk) const Text('• obhod, ki se še snema'),
          const SizedBox(height: 12),
          const Text('Če se odjavite zdaj, bodo izgubljeni. Počakajte, da se '
              'pošljejo – ko je naprava povezana, se pošljejo sami.'),
          if (unsent.activeWalk) ...[
            const SizedBox(height: 8),
            const Text('Obhod pred odjavo zaključite.'),
          ],
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
          child: const Text('Odjavi in zavrzi'),
        ),
      ],
    ),
  );
  return discard == true;
}
