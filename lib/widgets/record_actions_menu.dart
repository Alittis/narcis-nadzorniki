import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

/// TB-2: the per-row action menu on a record. Delete is the only action
/// for now; the menu shape is what lets edit join it later without disturbing
/// the row's tap target, which still opens the detail view.
///
/// Public so it can be widget-tested against a real AppState without seeding
/// the whole screen.
class RecordActionsMenu extends StatelessWidget {
  const RecordActionsMenu({super.key, required this.record, this.onDeleted});

  final Disturbance record;

  /// Called after a delete is queued. The list needs nothing (the row vanishes
  /// on its own, because `AppState.records` hides it), but the detail screen
  /// has to pop — it would otherwise be showing a record that no longer exists.
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'Dejanja',
      onSelected: (value) {
        if (value == 'delete') {
          _handleDelete(context);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 12),
              Text('Izbriši zapis'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleDelete(BuildContext context) async {
    final state = context.read<AppState>();

    // The item is deliberately left enabled for a locked record: a greyed-out
    // row that cannot be tapped tells the user nothing about why.
    if (record.isLockedByReview) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Zapisa ni mogoče izbrisati'),
          content: Text(
            'Zapis je v obravnavi (status: „${record.caseStatus}"). '
            'Zapise, ki jih je pisarna že prevzela v obravnavo, lahko '
            'odstrani samo pisarna.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Razumem'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Izbriši zapis?'),
        content: const Text(
          'Zapis bo trajno izbrisan skupaj s fotografijami. '
          'Tega ni mogoče razveljaviti.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Prekliči'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Izbriši'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // The row vanishes from `records` the moment this is queued, so there is no
    // second tap to guard against here.
    final purged = await state.deleteRecord(record);
    if (!context.mounted) return;
    // Messenger first: popping the detail route would take this context's
    // ScaffoldMessenger with it, and the confirmation would never be seen.
    final messenger = ScaffoldMessenger.of(context);
    onDeleted?.call();
    messenger.showSnackBar(
      SnackBar(
        content: Text(purged
            ? 'Zapis je izbrisan.'
            : 'Zapis bo izbrisan ob naslednji sinhronizaciji.'),
      ),
    );
  }
}
