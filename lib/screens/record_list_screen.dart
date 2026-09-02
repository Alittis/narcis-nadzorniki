import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/walk_detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

class RecordListScreen extends StatelessWidget {
  const RecordListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Seznam zapisov'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final sorted = state.records
              .where(state.isAuthoredByCurrentUser)
              .toList()
            ..sort((a, b) => b.observedAt.compareTo(a.observedAt));

          if (sorted.isEmpty) {
            return const Center(child: Text('Ni vnosov.'));
          }

          return ListView.separated(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
            itemBuilder: (context, index) {
              final record = sorted[index];
              final typePreview = record.types.isEmpty
                  ? 'Brez tipa'
                  : record.types.map((t) => t.typeName).join(', ');
              // TB-17: the walk this record was captured during, if any. The
              // link can be set while the walk itself is still local-only or
              // simply not pulled yet, so resolution is allowed to fail — see
              // ObhodLink.
              final linkedWalk = state.walks
                  .where((w) => w.id == record.obhodId)
                  .firstOrNull;
              return ListTile(
                isThreeLine: record.obhodId != null,
                leading: Icon(
                  record.pendingSync ? Icons.sync_problem : Icons.check_circle,
                  color: record.pendingSync ? Colors.orange : Colors.green,
                ),
                title: Text(typePreview),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordStatusLine(
                      date: dateFormat.format(record.observedAt.toLocal()),
                      caseStatus: record.caseStatus,
                    ),
                    if (record.obhodId != null)
                      ObhodLink(walk: linkedWalk, dateFormat: dateFormat),
                  ],
                ),
                trailing: RecordActionsMenu(record: record),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DetailScreen(record: record),
                    ),
                  );
                },
              );
            },
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemCount: sorted.length,
          );
        },
      ),
    );
  }

}

/// TB-2: the per-row action menu in Seznam zapisov. Delete is the only action
/// for now; the menu shape is what lets edit join it later without disturbing
/// the row's tap target, which still opens the detail view.
///
/// Public so it can be widget-tested against a real AppState without seeding
/// the whole screen.
class RecordActionsMenu extends StatelessWidget {
  const RecordActionsMenu({super.key, required this.record});

  final Disturbance record;

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(purged
            ? 'Zapis je izbrisan.'
            : 'Zapis bo izbrisan ob naslednji sinhronizaciji.'),
      ),
    );
  }
}

/// Subtitle line for a record row: observed date, then the case status (TB-30).
///
/// Public so it can be widget-tested directly — seeding `AppState` would mean
/// adding a test-only seam to production state for one row of UI.
///
/// Dot **plus label**, not a bare dot. Two reasons. The tile's `leading` icon
/// already speaks in colour (green = synced, orange = pending), so an unlabelled
/// coloured dot here would read as a second sync indicator; and an unlabelled
/// colour is exactly what made TB-26's first cut unreadable. The dot comes from
/// `recordMarkerColorForStatus`, so this list, the detail card, the filter sheet
/// and both maps all show one status in one colour.
class RecordStatusLine extends StatelessWidget {
  const RecordStatusLine({super.key, required this.date, required this.caseStatus});

  final String date;
  final String caseStatus;

  @override
  Widget build(BuildContext context) {
    // Wrap, not Row. 'Predano drugi službi' after a full dd.MM.yyyy HH:mm
    // timestamp overflows a 320 dp phone by ~85 px, and a Row can only fix that
    // by ellipsizing — which would eat either a date or a status, both of which
    // are the point. Wrapping to a second line loses nothing. The dot and its
    // label are one Row so they always travel together.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 2,
      children: [
        Text(date),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: recordMarkerColorForStatus(caseStatus),
              ),
            ),
            // Flexible as the last resort: the Wrap above already gives the
            // status its own line when the two do not fit side by side, but a
            // large text scale can still outgrow one line, and a dropped glyph
            // beats a yellow overflow stripe across the row.
            Flexible(
              child: Text(
                caseStatus,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The obhod a record was captured during (TB-17), as the row's second subtitle
/// line. Tappable through to the walk.
///
/// [walk] is null when `obhodId` is set but the walk is not in `AppState.walks`
/// — a real case, not defensive padding: a disturbance logged during an active
/// walk carries the link before that walk has ever reached the server, and a
/// fresh install pulls records and walks independently. There is nothing to
/// navigate to then, so the row says it belongs to a patrol and stops there
/// rather than offering a tap that would dead-end.
class ObhodLink extends StatelessWidget {
  const ObhodLink({super.key, required this.walk, required this.dateFormat});

  final Walk? walk;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resolved = walk;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.directions_walk, size: 14, color: colors.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            resolved == null ? 'Del obhoda' : walkLabel(resolved, dateFormat),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: resolved == null ? colors.onSurfaceVariant : colors.primary,
              decoration:
                  resolved == null ? null : TextDecoration.underline,
              decorationColor: colors.primary,
            ),
          ),
        ),
      ],
    );

    if (resolved == null) {
      return Padding(padding: const EdgeInsets.only(top: 2), child: content);
    }
    return InkWell(
      // Opens the walk instead of the record. The padding is what keeps this a
      // real tap target inside a row whose own onTap opens the disturbance.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WalkDetailScreen(walkId: resolved.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: content,
      ),
    );
  }
}
