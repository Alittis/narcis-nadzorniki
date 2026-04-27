import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';

class LegacyDetailScreen extends StatelessWidget {
  const LegacyDetailScreen({super.key, required this.record});

  final LegacyDisturbance record;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final observed = record.observedAt == null
        ? '-'
        : dateFormat.format(record.observedAt!.toLocal());
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Zgodovinski zapis'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.purple.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.history, color: Colors.purple.shade700),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Zgodovinski podatek (vir: Notranjski regijski park, 2025). '
                    'Samo za ogled – zapisa ni mogoče urejati.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Čas dogodka'),
          Text(observed),
          const Divider(height: 32),
          _sectionTitle(context, 'Lokacija'),
          Text('${record.latitude.toStringAsFixed(5)}, ${record.longitude.toStringAsFixed(5)}'),
          if (record.locationAccuracy != null) ...[
            const SizedBox(height: 4),
            Text(record.locationAccuracy!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (record.plusCode != null) ...[
            const SizedBox(height: 4),
            Text(record.plusCode!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const Divider(height: 32),
          _sectionTitle(context, 'Kategorije motenj'),
          if (record.categoriesByGroup.isEmpty)
            const Text('—')
          else
            ...record.categoriesByGroup.entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.key, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: entry.value.map((value) => Chip(label: Text(value))).toList(),
                    ),
                  ],
                ),
              ),
            ),
          if (record.description != null && record.description!.isNotEmpty) ...[
            const Divider(height: 32),
            _sectionTitle(context, 'Opis'),
            Text(record.description!),
          ],
          if (record.actionTaken != null && record.actionTaken!.isNotEmpty) ...[
            const Divider(height: 32),
            _sectionTitle(context, 'Način obravnave'),
            Text(record.actionTaken!),
          ],
          if (record.observer != null && record.observer!.isNotEmpty) ...[
            const Divider(height: 32),
            _sectionTitle(context, 'Opazovalec'),
            Text(record.observer!),
          ],
          if (record.photoUrls.isNotEmpty) ...[
            const Divider(height: 32),
            _sectionTitle(context, 'Fotografije'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: record.photoUrls
                  .map(
                    (url) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        url,
                        width: 140,
                        height: 140,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => Container(
                          width: 140,
                          height: 140,
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}
