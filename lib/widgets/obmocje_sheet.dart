import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

// ── Sublayer presentation (shared with the layer picker) ────────────────────
// Swatch/badge colours approximate the narcis-vibed palette. On-map colours
// come from GeoServer's SLD; these are just for the picker dots and the
// identify badges.
Color zosColor(ZosKind k) {
  switch (k) {
    case ZosKind.n2k:
      return const Color(0xFFD98210); // orange (POO); POV shows red, see _badge
    case ZosKind.zo:
      return const Color(0xFF6CC092); // green
    case ZosKind.epo:
      return const Color(0xFFB8A800); // darkened yellow (visible as a dot)
    case ZosKind.nv:
      return const Color(0xFFD6161F); // red
    case ZosKind.nvj:
      return const Color(0xFF8E1F12); // dark red (distinguish jame from NV)
  }
}

/// Full name, for the picker rows.
String zosTitle(ZosKind k) {
  switch (k) {
    case ZosKind.n2k:
      return 'Natura 2000';
    case ZosKind.zo:
      return 'Zavarovana območja';
    case ZosKind.epo:
      return 'Ekološko pomembna območja';
    case ZosKind.nv:
      return 'Naravne vrednote';
    case ZosKind.nvj:
      return 'Naravne vrednote – jame';
  }
}

/// Short label, for identify badges/rows.
String zosShort(ZosKind k) {
  switch (k) {
    case ZosKind.n2k:
      return 'Natura 2000';
    case ZosKind.zo:
      return 'Zavarovano območje';
    case ZosKind.epo:
      return 'EPO';
    case ZosKind.nv:
      return 'Naravna vrednota';
    case ZosKind.nvj:
      return 'Naravna vrednota – jama';
  }
}

/// Badge label + colour for one identified feature. N2k keeps the POV/POO
/// distinction (red/orange); other kinds use their sublayer label + colour.
(String, Color) _badge(ObmocjeFeature f) {
  if (f.kind == ZosKind.n2k && f.tip.isNotEmpty) {
    final pov = f.tip.toUpperCase().startsWith('POV');
    return (
      pov ? 'Natura 2000 · POV' : 'Natura 2000 · POO',
      pov ? const Color(0xFFE30000) : const Color(0xFFD98210),
    );
  }
  return (zosShort(f.kind), zosColor(f.kind));
}

// ── Identify result sheet ───────────────────────────────────────────────────

/// Bottom sheet for the protected areas under a map tap, from one WMS
/// GetFeatureInfo across the active sublayers. Several hits (overlap is the
/// norm) open as a list; a row-tap drills into that area's detail; a single hit
/// opens detail directly. All attributes are already in [features].
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
            Builder(builder: (context) {
              final (label, color) = _badge(f);
              return InkWell(
                onTap: () => onSelect(f),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black26),
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
                              f.koda.isEmpty ? label : '$label · ${f.koda}',
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
              );
            }),
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
    final (label, color) = _badge(feature);
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
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
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
          for (final r in feature.rows)
            _DetailRow(label: r.key, value: r.value),
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
