import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

// ── Sublayer presentation ───────────────────────────────────────────────────
// The map draws the web map's own style, served by the VPS (TB-47). A swatch
// takes the feature's colour from that style's legend (`ObmocjeFeature.color`)
// and its shape from how the style draws the feature: areas filled — Natura
// 2000 POV as an outline, because the phone has no hatch — and points as their
// layer's mark (dot, triangle or cave).

/// The on-map mark for one identified feature: its shape + colour.
enum ZosShape { polygon, polygonOutline, circle, triangle, cave }

class ZosSymbol {
  const ZosSymbol(this.color, this.shape);
  final Color color;
  final ZosShape shape;
}

/// Grey when the legend had no colour for the feature.
const Color _noLegendColor = Color(0xFF8E8E93);

/// The map's mark for [f]: the legend colour of its class, in the shape the
/// served style draws it with.
ZosSymbol zosSymbol(ObmocjeFeature f) {
  final argb = f.color;
  final color = argb == null ? _noLegendColor : Color(argb);
  if (!f.isPoint) {
    final outline = f.kind == ZosKind.n2k && f.cls == 'POV';
    return ZosSymbol(
        color, outline ? ZosShape.polygonOutline : ZosShape.polygon);
  }
  switch (f.kind) {
    case ZosKind.nv:
      return ZosSymbol(color, ZosShape.triangle);
    case ZosKind.nvj:
    case ZosKind.epo:
      return ZosSymbol(color, ZosShape.cave);
    case ZosKind.n2k:
    case ZosKind.zo:
    case ZosKind.mvo:
      return ZosSymbol(color, ZosShape.circle);
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
    case ZosKind.mvo:
      return 'Mednarodno varovana območja';
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
    case ZosKind.mvo:
      return 'Mednarodno varovano območje';
  }
}

/// Text label for one identified feature. N2k keeps the POV/POO distinction;
/// other kinds use their sublayer's short label. (Colour + shape: [zosSymbol].)
String _badgeLabel(ObmocjeFeature f) {
  if (f.kind == ZosKind.n2k && f.cls.isNotEmpty) return 'Natura 2000 · ${f.cls}';
  return zosShort(f.kind);
}

// ── Identify result sheet ───────────────────────────────────────────────────

/// Bottom sheet for the protected areas under a map tap (`ObmocjaStore.identify`
/// across the active sublayers). Several hits (overlap is the norm) open as a
/// list; a row-tap drills into that area's detail; a single hit opens detail
/// directly. All attributes are already in [features].
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
              final label = _badgeLabel(f);
              return InkWell(
                onTap: () => onSelect(f),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      _ZosSwatch(zosSymbol(f)),
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
    final label = _badgeLabel(feature);
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
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ZosSwatch(zosSymbol(feature), size: 13),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
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

/// Small swatch drawing a feature's map mark — colour + shape from
/// [zosSymbol]: a translucent area for polygons, an outline for POV areas,
/// and the per-layer point marks (circle / triangle / cave glyph).
class _ZosSwatch extends StatelessWidget {
  const _ZosSwatch(this.symbol, {this.size = 16});

  final ZosSymbol symbol;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _ZosSwatchPainter(symbol),
      );
}

class _ZosSwatchPainter extends CustomPainter {
  const _ZosSwatchPainter(this.symbol);

  final ZosSymbol symbol;

  @override
  void paint(Canvas canvas, Size size) {
    final c = symbol.color;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x66000000);
    switch (symbol.shape) {
      case ZosShape.polygon:
        final rr = RRect.fromRectAndRadius(
            (Offset.zero & size).deflate(1), const Radius.circular(3));
        canvas.drawRRect(rr, Paint()..color = c.withValues(alpha: 0.55));
        canvas.drawRRect(rr, edge);
      case ZosShape.polygonOutline:
        final rr = RRect.fromRectAndRadius(
            (Offset.zero & size).deflate(1.2), const Radius.circular(3));
        canvas.drawRRect(
            rr,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..color = c);
      case ZosShape.circle:
        final ctr = size.center(Offset.zero);
        final r = size.width / 2 - 1.5;
        canvas.drawCircle(ctr, r, Paint()..color = c);
        canvas.drawCircle(ctr, r, edge);
      case ZosShape.triangle:
        final p = Path()
          ..moveTo(size.width / 2, 1.5)
          ..lineTo(size.width - 1.5, size.height - 2)
          ..lineTo(1.5, size.height - 2)
          ..close();
        canvas.drawPath(p, Paint()..color = c);
        canvas.drawPath(p, edge);
      case ZosShape.cave:
        // Cave entrance: an arch/dome rising from a flat base line, with the
        // dark entrance dot resting on that base — the web's cave mark.
        // NB: addArc sweeps clockwise from +x, so (math.pi, math.pi) is the TOP
        // half (arch); (0, math.pi) would be the bottom half (an upside-down bowl).
        final r = size.width / 2 - 1.5;
        final dotR = r * 0.22;
        final baseY = size.height / 2 + r / 2;
        final ctr = Offset(size.width / 2, baseY);
        final dome = Path()
          ..addArc(Rect.fromCircle(center: ctr, radius: r), math.pi, math.pi)
          ..close();
        canvas.drawPath(dome, Paint()..color = c);
        canvas.drawPath(dome, edge);
        canvas.drawCircle(Offset(size.width / 2, baseY - dotR), dotR,
            Paint()..color = const Color(0xFF0C000B));
    }
  }

  @override
  bool shouldRepaint(_ZosSwatchPainter old) =>
      old.symbol.color != symbol.color || old.symbol.shape != symbol.shape;
}
