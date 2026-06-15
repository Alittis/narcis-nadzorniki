import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

const _povColor = Color(0xFFE30000);
const _pooColor = Color(0xFFD98210);

Color _color(ObmocjeFeature f) => f.isPov ? _povColor : _pooColor;
String _badge(ObmocjeFeature f) => f.isPov ? 'POV (SPA)' : 'POO (SAC)';

/// Bottom sheet for the Natura 2000 areas under a map tap, from a single WMS
/// GetFeatureInfo. SPA (POV) and SAC (POO) overlap, so a tap usually returns
/// more than one: several hits open as a list and a row-tap drills into that
/// area's detail; a single hit opens the detail directly. All attributes are
/// already in [features] — there is no further fetch.
Future<void> showObmocjaSheet(
  BuildContext context,
  List<ObmocjeFeature> features,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ObmocjaSheet(features: features),
  );
}

class _ObmocjaSheet extends StatefulWidget {
  const _ObmocjaSheet({required this.features});

  final List<ObmocjeFeature> features;

  @override
  State<_ObmocjaSheet> createState() => _ObmocjaSheetState();
}

class _ObmocjaSheetState extends State<_ObmocjaSheet> {
  ObmocjeFeature? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.features.length == 1) _selected = widget.features.first;
  }

  bool get _canGoBack => widget.features.length > 1;

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: selected == null
            ? _FeatureList(
                features: widget.features,
                onSelect: (f) => setState(() => _selected = f),
              )
            : _FeatureDetail(
                feature: selected,
                onBack:
                    _canGoBack ? () => setState(() => _selected = null) : null,
              ),
      ),
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.features, required this.onSelect});

  final List<ObmocjeFeature> features;
  final ValueChanged<ObmocjeFeature> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_moon_outlined, size: 18),
              const SizedBox(width: 6),
              Text('Območja na tej točki',
                  style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 4),
          for (final f in features)
            InkWell(
              onTap: () => onSelect(f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _color(f),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.ime.isEmpty ? '—' : f.ime,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${_badge(f)} · ${f.koda}',
                            style: TextStyle(
                                color: scheme.onSurfaceVariant, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FeatureDetail extends StatelessWidget {
  const _FeatureDetail({required this.feature, this.onBack});

  final ObmocjeFeature feature;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badgeColor = _color(feature);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onBack != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    onTap: onBack,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.arrow_back, size: 18),
                    ),
                  ),
                ),
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
                  _badge(feature),
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
            feature.ime.isEmpty ? '—' : feature.ime,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (feature.koda.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              feature.koda,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          if (feature.biogeoRegion.isNotEmpty)
            _DetailRow(label: 'Biogeografska regija', value: feature.biogeoRegion),
          if (feature.povrsinaHa != null)
            _DetailRow(
                label: 'Površina',
                value: '${feature.povrsinaHa!.toStringAsFixed(1)} ha'),
          if (feature.datZac.isNotEmpty)
            _DetailRow(label: 'Datum začetka', value: feature.datZac),
          if (feature.opis.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(feature.opis,
                style: const TextStyle(fontSize: 13, height: 1.35)),
          ],
        ],
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
