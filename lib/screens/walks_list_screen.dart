import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/walk_detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

class WalksListScreen extends StatelessWidget {
  const WalksListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Seznam obhodov'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final sorted = state.walks
              .where(state.isWalkAuthoredByCurrentUser)
              .toList()
            ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

          if (sorted.isEmpty) {
            return const Center(child: Text('Ni obhodov.'));
          }

          return ListView.separated(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
            itemBuilder: (context, index) {
              final walk = sorted[index];
              return ListTile(
                leading: Icon(
                  walk.pendingSync
                      ? Icons.sync_problem
                      : Icons.directions_walk,
                  color: walk.pendingSync ? Colors.orange : Colors.green,
                ),
                title: Text(walk.name?.isNotEmpty == true
                    ? walk.name!
                    : dateFormat.format(walk.startedAt.toLocal())),
                subtitle: Text(_subtitle(walk, dateFormat)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WalkDetailScreen(walkId: walk.id),
                    ),
                  );
                },
              );
            },
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemCount: sorted.length,
          );
        },
      ),
    );
  }

  String _subtitle(Walk walk, DateFormat fmt) {
    final start = fmt.format(walk.startedAt.toLocal());
    final mins = walk.duration.inMinutes;
    final pts = walk.displayPointCount;
    final parts = <String>[start, '$mins min', '$pts točk'];
    if ((walk.disturbanceCount ?? 0) > 0) {
      parts.add('${walk.disturbanceCount} motenj');
    }
    return parts.join(' • ');
  }
}
