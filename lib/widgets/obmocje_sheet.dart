import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

/// Bottom sheet shown when a Natura 2000 area is tapped on the map. Title, code
/// and POO/POV badge come from geometry props we already hold (instant); the
/// rest (region, area, description, date) is fetched lazily from
/// `/vib/zos-detail/:id` and degrades gracefully when offline.
Future<void> showObmocjeSheet(
  BuildContext context,
  ObmocjaStore store,
  N2kArea area,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ObmocjeSheet(store: store, area: area),
  );
}

class _ObmocjeSheet extends StatelessWidget {
  const _ObmocjeSheet({required this.store, required this.area});

  final ObmocjaStore store;
  final N2kArea area;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPov = area.isPov;
    final badgeColor = isPov ? const Color(0xFFE30000) : const Color(0xFFD98210);
    final badgeLabel = isPov ? 'POV (SPA)' : 'POO (SAC)';
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_moon_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text('Natura 2000',
                      style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badgeLabel,
                      style: TextStyle(
                        color: badgeColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                area.ime.isEmpty ? '—' : area.ime,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (area.koda.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  area.koda,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              FutureBuilder<ObmocjeDetail?>(
                future: store.loadDetail(area.id),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final d = snap.data;
                  if (d == null) {
                    return Text(
                      'Podrobnosti niso na voljo brez povezave.',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 13),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (d.biogeoRegion.isNotEmpty)
                        _DetailRow(
                            label: 'Biogeografska regija',
                            value: d.biogeoRegion),
                      if (d.povrsinaHa != null)
                        _DetailRow(
                            label: 'Površina',
                            value: '${d.povrsinaHa!.toStringAsFixed(1)} ha'),
                      if (d.datUstan.isNotEmpty)
                        _DetailRow(
                            label: 'Datum ustanovitve', value: d.datUstan),
                      if (d.opis.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(d.opis,
                            style: const TextStyle(fontSize: 13, height: 1.35)),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
