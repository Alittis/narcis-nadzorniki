import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

// ── Sublayer presentation ───────────────────────────────────────────────────
// The map tiles are server-rendered by the NarcIS GeoServer; these swatches
// mirror that SLD so the identify list shows the SAME colour + shape the user
// sees on the map. Colours/rules captured from GetLegendGraphic (FORMAT=
// application/json) on the SI.NARCIS ZOS_* layers, 2026-06-15 — if ARSO restyles
// a layer, re-pull and update here. Shape is the feature's real geometry: areas
// (polygons) vs the per-layer point marks (circle / triangle / cave).

/// The on-map mark for one identified feature: its SLD shape + fill colour.
enum ZosShape { polygon, polygonOutline, circle, triangle, cave }

class ZosSymbol {
  const ZosSymbol(this.color, this.shape);
  final Color color;
  final ZosShape shape;
}

/// N2k splits POV (SPA, red outline) from POO (SAC, orange fill) on its `tip`.
bool _n2kIsPov(ObmocjeFeature f) => f.tip.toUpperCase().startsWith('POV');

/// ZO is coloured per `ZO_VRSTA` (7 categories), same colour for its polygon
/// and point renderings. Unknown vrsta falls back to the park green.
Color _zoVrstaColor(String vrsta) {
  switch (vrsta.toLowerCase().trim()) {
    case 'narodni park':
      return const Color(0xFF6CC092);
    case 'regijski park':
      return const Color(0xFF80B537);
    case 'krajinski park':
      return const Color(0xFF8D8634);
    case 'naravni spomenik':
      return const Color(0xFFCD4E1B);
    case 'naravni rezervat':
      return const Color(0xFFD01C8B);
    case 'strogi naravni rezervat':
      return const Color(0xFFE683C0);
    case 'spomenik oblikovane narave':
      return const Color(0xFFAB61E4);
    default:
      return const Color(0xFF6CC092);
  }
}

/// The real GeoServer symbol for [f] — colour + shape — matched by the same
/// attribute its SLD rule keys on (tip / ZO_VRSTA / NV_POMEN / NV_STATUS) and
/// by geometry (polygon vs point, via [ObmocjeFeature.isPoint]).
ZosSymbol zosSymbol(ObmocjeFeature f) {
  switch (f.kind) {
    case ZosKind.n2k:
      return _n2kIsPov(f)
          ? const ZosSymbol(Color(0xFFE30000), ZosShape.polygonOutline)
          : const ZosSymbol(Color(0xFFD98210), ZosShape.polygon);
    case ZosKind.zo:
      return ZosSymbol(_zoVrstaColor(f.vrsta),
          f.isPoint ? ZosShape.circle : ZosShape.polygon);
    case ZosKind.epo:
      return f.isPoint
          ? const ZosSymbol(Color(0xFF0C000B), ZosShape.circle)
          : const ZosSymbol(Color(0xFFFBFB7F), ZosShape.polygon);
    case ZosKind.nv:
      if (f.isPoint) {
        final lokalni = f.pomen.toLowerCase().startsWith('lokal');
        return ZosSymbol(
            lokalni ? const Color(0xFF178D89) : const Color(0xFFD6161F),
            ZosShape.triangle);
      }
      return f.status.toUpperCase() == 'OP'
          ? const ZosSymbol(Color(0xFFD6161F), ZosShape.polygonOutline)
          : const ZosSymbol(Color(0xFFD6161F), ZosShape.polygon);
    case ZosKind.nvj:
      return const ZosSymbol(Color(0xFFD6161F), ZosShape.cave);
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

/// Text label for one identified feature. N2k keeps the POV/POO distinction;
/// other kinds use their sublayer's short label. (Colour + shape: [zosSymbol].)
String _badgeLabel(ObmocjeFeature f) {
  if (f.kind == ZosKind.n2k && f.tip.isNotEmpty) {
    return _n2kIsPov(f) ? 'Natura 2000 · POV' : 'Natura 2000 · POO';
  }
  return zosShort(f.kind);
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

/// Small swatch drawing a feature's real GeoServer mark — colour + shape from
/// [zosSymbol]: a translucent area for polygons, an outline for POV/OP areas,
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
        // Cave cross-section: a flat-topped red half-disc (the cavity, curving
        // down) with the dark entrance dot resting on the rim — the GeoServer
        // jame mark.
        final r = size.width / 2 - 1.5;
        final lineY = size.height * 0.5;
        final ctr = Offset(size.width / 2, lineY);
        final dotR = r * 0.22;
        final cavity = Path()
          ..addArc(Rect.fromCircle(center: ctr, radius: r), 0, math.pi)
          ..close();
        canvas.drawPath(cavity, Paint()..color = c);
        canvas.drawPath(cavity, edge);
        canvas.drawCircle(Offset(size.width / 2, lineY - dotR), dotR,
            Paint()..color = const Color(0xFF0C000B));
    }
  }

  @override
  bool shouldRepaint(_ZosSwatchPainter old) =>
      old.symbol.color != symbol.color || old.symbol.shape != symbol.shape;
}
