import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
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
              return ListTile(
                leading: Icon(
                  record.pendingSync ? Icons.sync_problem : Icons.check_circle,
                  color: record.pendingSync ? Colors.orange : Colors.green,
                ),
                title: Text(typePreview),
                subtitle: RecordStatusLine(
                  date: dateFormat.format(record.observedAt.toLocal()),
                  caseStatus: record.caseStatus,
                ),
                trailing: const Icon(Icons.chevron_right),
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
