import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/hotspot.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

/// TB-39: how a new record on a hot spot starts — the speed dial's two
/// intents (ARCHITECTURE §14), so the sheet adds no third way in.
enum HotspotEntry { photo, codebook }

/// TB-39 phase 1: a tap on a hot spot on the home map. Names it, lists its
/// records newest first (from the org's records on this device), and offers
/// a new record on it. Returns the entry chosen, or null.
Future<HotspotEntry?> showHotspotSheet(BuildContext context, Hotspot hotspot) {
  return showModalBottomSheet<HotspotEntry>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => HotspotSheet(hotspot: hotspot),
  );
}

/// "1 zapis", "2 zapisa", "3 zapisi", "5 zapisov" (Slovene dual and plural).
String zapisovLabel(int n) {
  final r = n % 100;
  if (r == 1) return '$n zapis';
  if (r == 2) return '$n zapisa';
  if (r == 3 || r == 4) return '$n zapisi';
  return '$n zapisov';
}

class HotspotSheet extends StatelessWidget {
  const HotspotSheet({super.key, required this.hotspot});

  final Hotspot hotspot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    final records = context
        .watch<AppState>()
        .records
        .where((r) => r.hotspotId == hotspot.id)
        .toList()
      ..sort((a, b) => b.observedAt.compareTo(a.observedAt));

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(width: 28, height: 28, child: HotspotMarker()),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hotspot.name,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Vroča točka · ${records.isEmpty ? 'še brez zapisov' : zapisovLabel(records.length)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (records.isNotEmpty) ...[
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = records[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          r.types.isEmpty
                              ? 'Brez tipa'
                              : r.types.map((t) => t.typeName).join(', '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: RecordStatusLine(
                          date: dateFormat.format(r.observedAt.toLocal()),
                          caseStatus: r.caseStatus,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailScreen(record: r),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Nov zapis na tej vroči točki',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          Navigator.of(context).pop(HotspotEntry.photo),
                      icon: const Icon(Icons.photo_camera, size: 18),
                      label: const Text('Foto'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          Navigator.of(context).pop(HotspotEntry.codebook),
                      icon: const Icon(Icons.list_alt, size: 18),
                      label: const Text('Šifrant'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
