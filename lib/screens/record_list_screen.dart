import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';

class RecordListScreen extends StatelessWidget {
  const RecordListScreen({
    super.key,
    required this.records,
  });

  final List<Disturbance> records;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final sorted = [...records]..sort((a, b) => b.observedAt.compareTo(a.observedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Seznam zapisov'),
      ),
      body: sorted.isEmpty
          ? const Center(child: Text('Ni vnosov.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
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
                  subtitle: Text(dateFormat.format(record.observedAt)),
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
            ),
    );
  }
}
