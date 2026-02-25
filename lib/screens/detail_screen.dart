import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({
    super.key,
    required this.record,
  });

  final Disturbance record;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podrobnosti zapisa'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _InfoRow(label: 'Status sinhronizacije', value: record.pendingSync ? 'V čakanju' : 'Sinhronizirano'),
          _InfoRow(label: 'Datum/čas', value: dateFormat.format(record.observedAt)),
          _InfoRow(
            label: 'Lokacija',
            value: '${record.latitude.toStringAsFixed(5)}, ${record.longitude.toStringAsFixed(5)}',
          ),
          _InfoRow(label: 'Natančnost', value: record.locationAccuracy),
          _InfoRow(label: 'Ukrepanje', value: record.actionTaken),
          _InfoRow(
            label: 'Opazovalci',
            value: record.observers.isEmpty ? '—' : record.observers.join(', '),
          ),
          const SizedBox(height: 12),
          Text('Tipi motenj', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...record.types.map((type) => Text('• ${type.display}')),
          if (record.proposedType != null && record.proposedType!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Predlagan tip: ${record.proposedType}'),
          ],
          const SizedBox(height: 16),
          Text('Opis', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(record.description.isEmpty ? '—' : record.description),
          const SizedBox(height: 16),
          Text('Fotografije', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (record.photoPaths.isEmpty)
            const Text('Ni pripetih fotografij.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: record.photoPaths
                  .map(
                    (path) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(path),
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
