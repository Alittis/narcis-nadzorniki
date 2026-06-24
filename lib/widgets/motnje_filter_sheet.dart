import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/data/disturbance_group_colors.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';

String _authorLabel(String key, String? me) {
  final local = key.contains('@') ? key.split('@').first : key;
  return key == me?.toLowerCase() ? '$local (jaz)' : local;
}

String _dayLabel(DateTime d) =>
    '${d.day}. ${d.month}. ${(d.year % 100).toString().padLeft(2, '0')}';

/// Filter picker for the home-map Motnje layer (TB-6 / TB-18). Opened by tapping
/// the Motnje chip (same chip→sheet pattern as Območja); edits push live to
/// [onChanged] / [onShowChanged] so the map redraws behind the sheet. [records]
/// is the full Motnje set — it drives the author list, the date span and the
/// per-day histogram.
Future<void> showMotnjeFilterSheet(
  BuildContext context, {
  required bool showMotnje,
  required void Function(bool) onShowChanged,
  required MotnjeFilter filter,
  required List<Disturbance> records,
  required String? currentUserEmail,
  required void Function(MotnjeFilter) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MotnjeFilterSheet(
      showMotnje: showMotnje,
      onShowChanged: onShowChanged,
      initial: filter,
      records: records,
      currentUserEmail: currentUserEmail,
      onChanged: onChanged,
    ),
  );
}

class _MotnjeFilterSheet extends StatefulWidget {
  const _MotnjeFilterSheet({
    required this.showMotnje,
    required this.onShowChanged,
    required this.initial,
    required this.records,
    required this.currentUserEmail,
    required this.onChanged,
  });

  final bool showMotnje;
  final void Function(bool) onShowChanged;
  final MotnjeFilter initial;
  final List<Disturbance> records;
  final String? currentUserEmail;
  final void Function(MotnjeFilter) onChanged;

  @override
  State<_MotnjeFilterSheet> createState() => _MotnjeFilterSheetState();
}

class _MotnjeFilterSheetState extends State<_MotnjeFilterSheet> {
  late bool _show;
  late Set<AgeBucket> _buckets;
  late Set<String> _authors; // 0 or 1 element (single-select UI)
  late Set<String> _groups; // explicit selected group codes (subset of present)
  late final List<String> _authorKeys;
  late final List<(String, String)> _presentGroups; // (code, name), present only
  DateTime? _startDay;
  late final int _dayCount;
  late RangeValues _days;

  @override
  void initState() {
    super.initState();
    _show = widget.showMotnje;
    _buckets = {...widget.initial.ageBuckets};
    _authors = {...widget.initial.authors};
    _authorKeys = authorsIn(widget.records, widget.currentUserEmail);
    _presentGroups = groupsIn(widget.records);

    // null in the model means "all categories" → start every present group
    // ticked; an explicit set restores that subset.
    final allCodes = {for (final g in _presentGroups) g.$1};
    _groups =
        widget.initial.groups == null ? allCodes : {...widget.initial.groups!};

    final span = observedSpan(widget.records);
    if (span == null) {
      _dayCount = 0;
    } else {
      _startDay = DateTime(span.$1.year, span.$1.month, span.$1.day);
      final endDay = DateTime(span.$2.year, span.$2.month, span.$2.day);
      _dayCount = endDay.difference(_startDay!).inDays;
    }
    var lo = 0, hi = _dayCount;
    if (_startDay != null && widget.initial.from != null) {
      lo = _dayIndexOf(widget.initial.from!).clamp(0, _dayCount);
    }
    if (_startDay != null && widget.initial.to != null) {
      hi = _dayIndexOf(widget.initial.to!).clamp(0, _dayCount);
    }
    _days = RangeValues(lo.toDouble(), hi.toDouble());
  }

  int _dayIndexOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).difference(_startDay!).inDays;

  DateTime _dayAt(int i) => _startDay!.add(Duration(days: i));

  // Inclusive last microsecond of day i.
  DateTime _dayEnd(int i) => _startDay!
      .add(Duration(days: i + 1))
      .subtract(const Duration(microseconds: 1));

  bool get _dateActive =>
      _dayCount > 0 && (_days.start > 0 || _days.end < _dayCount);

  // null when every present group is ticked (no restriction); otherwise the
  // chosen subset — an empty set meaning "show none".
  Set<String>? get _groupsForFilter =>
      _groups.length == _presentGroups.length ? null : _groups;

  MotnjeFilter get _current => MotnjeFilter(
        ageBuckets: _buckets,
        authors: _authors,
        groups: _groupsForFilter,
        from: _dateActive ? _dayAt(_days.start.round()) : null,
        to: _dateActive ? _dayEnd(_days.end.round()) : null,
      );

  void _emit() => widget.onChanged(_current);

  void _reset() {
    setState(() {
      _buckets = {...allAgeBuckets};
      _authors = {};
      _groups = {for (final g in _presentGroups) g.$1};
      _days = RangeValues(0, _dayCount.toDouble());
    });
    _emit();
  }

  void _toggleBucket(AgeBucket b, bool on) {
    setState(() => on ? _buckets.add(b) : _buckets.remove(b));
    _emit();
  }

  void _selectAuthor(String? key) {
    setState(() => _authors = key == null ? {} : {key});
    _emit();
  }

  void _toggleGroup(String code, bool on) {
    setState(() => on ? _groups.add(code) : _groups.remove(code));
    _emit();
  }

  void _toggleAllGroups() {
    final all = {for (final g in _presentGroups) g.$1};
    setState(() => _groups = _groups.length == all.length ? <String>{} : all);
    _emit();
  }

  /// Records per day across the span, honouring age/author/category but NOT the
  /// date window — so the chart shows the full distribution the slider selects
  /// over.
  List<int> _dayCounts() {
    final f = MotnjeFilter(
      ageBuckets: _buckets,
      authors: _authors,
      groups: _groupsForFilter,
    );
    final counts = List<int>.filled(_dayCount + 1, 0);
    for (final r in widget.records) {
      if (!f.matches(r, currentUserEmail: widget.currentUserEmail)) continue;
      final di = _dayIndexOf(r.observedAt);
      if (di >= 0 && di <= _dayCount) counts[di]++;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = _current;
    final shown = widget.records
        .where(
            (r) => filter.matches(r, currentUserEmail: widget.currentUserEmail))
        .length;
    final selectedAuthor = _authors.isEmpty ? null : _authors.first;
    final allGroups = _groups.length == _presentGroups.length;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Motnje',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: filter.isActive ? _reset : null,
                        child: const Text('Ponastavi'),
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  title: const Text('Prikaži na zemljevidu'),
                  value: _show,
                  onChanged: (v) {
                    setState(() => _show = v);
                    widget.onShowChanged(v);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    _show
                        ? 'Prikazanih: $shown od ${widget.records.length}'
                        : 'Sloj skrit',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const Divider(height: 8),
                _sectionLabel('Starost'),
                _bucketRow(AgeBucket.recent, Colors.red, 'Zadnji mesec'),
                _bucketRow(AgeBucket.mid, Colors.orange, 'Zadnje leto'),
                _bucketRow(AgeBucket.old, Colors.blue, 'Starejše'),
                if (_authorKeys.length > 1) ...[
                  const Divider(height: 8),
                  _sectionLabel('Avtor'),
                  _authorRow(null, 'Vsi avtorji', selectedAuthor),
                  for (final key in _authorKeys)
                    _authorRow(key,
                        _authorLabel(key, widget.currentUserEmail), selectedAuthor),
                ],
                if (_presentGroups.length > 1) ...[
                  const Divider(height: 8),
                  _categorySection(allGroups),
                ],
                if (_dayCount > 0) ...[
                  const Divider(height: 8),
                  _sectionLabel('Obdobje'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_dayLabel(_dayAt(_days.start.round())),
                            style: theme.textTheme.bodySmall),
                        Text(_dayLabel(_dayAt(_days.end.round())),
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    child: SizedBox(
                      height: 40,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _DayHistogramPainter(
                          counts: _dayCounts(),
                          loIdx: _days.start.round(),
                          hiIdx: _days.end.round(),
                          inColor: theme.colorScheme.primary,
                          outColor: Colors.black26,
                        ),
                      ),
                    ),
                  ),
                  RangeSlider(
                    values: _days,
                    min: 0,
                    max: _dayCount.toDouble(),
                    divisions: _dayCount,
                    labels: RangeLabels(
                      _dayLabel(_dayAt(_days.start.round())),
                      _dayLabel(_dayAt(_days.end.round())),
                    ),
                    onChanged: (v) => setState(() => _days = v),
                    onChangeEnd: (_) => _emit(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );

  Widget _bucketRow(AgeBucket bucket, Color color, String label) {
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.trailing,
      value: _buckets.contains(bucket),
      onChanged: (v) => _toggleBucket(bucket, v ?? false),
      secondary: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
      title: Text(label),
    );
  }

  Widget _authorRow(String? key, String label, String? selected) {
    final isSelected = key == selected;
    return ListTile(
      dense: true,
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color:
            isSelected ? Theme.of(context).colorScheme.primary : Colors.black45,
      ),
      title: Text(label),
      onTap: () => _selectAuthor(key),
    );
  }

  Widget _categorySection(bool allGroups) {
    final summary = allGroups
        ? 'Vse kategorije'
        : (_groups.isEmpty ? 'Brez kategorij' : '${_groups.length} izbranih');
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: const Text('Kategorija',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      subtitle: Text(summary, style: Theme.of(context).textTheme.bodySmall),
      children: [
        CheckboxListTile(
          dense: true,
          tristate: true,
          controlAffinity: ListTileControlAffinity.trailing,
          value: _groups.isEmpty ? false : (allGroups ? true : null),
          onChanged: (_) => _toggleAllGroups(),
          title: const Text('Vse kategorije'),
        ),
        for (final g in _presentGroups)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.trailing,
            value: _groups.contains(g.$1),
            onChanged: (v) => _toggleGroup(g.$1, v ?? false),
            secondary: _groupCircle(g.$1),
            title: Text(g.$2),
          ),
      ],
    );
  }

  // The app's shared group token (tinted circle + code in the group's hue),
  // matching the type picker / form / detail screens — sized down for the
  // dense filter rows.
  Widget _groupCircle(String code) => Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: disturbanceGroupTint(code),
          shape: BoxShape.circle,
        ),
        child: Text(
          code,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: disturbanceGroupColor(code),
          ),
        ),
      );
}

/// Compact per-day bar chart for the Obdobje range slider. Bars in the selected
/// [loIdx, hiIdx] range use [inColor], the rest [outColor]; heights are
/// normalised to the busiest day.
class _DayHistogramPainter extends CustomPainter {
  _DayHistogramPainter({
    required this.counts,
    required this.loIdx,
    required this.hiIdx,
    required this.inColor,
    required this.outColor,
  });

  final List<int> counts;
  final int loIdx;
  final int hiIdx;
  final Color inColor;
  final Color outColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (counts.isEmpty) return;
    final maxC = counts.fold<int>(0, (m, c) => c > m ? c : m);
    if (maxC == 0) return;
    final n = counts.length;
    final barW = size.width / n;
    final inPaint = Paint()..color = inColor;
    final outPaint = Paint()..color = outColor;
    for (var i = 0; i < n; i++) {
      if (counts[i] == 0) continue;
      final h = (counts[i] / maxC) * size.height;
      final x = i * barW;
      final w = barW > 1.5 ? barW - 0.5 : barW;
      canvas.drawRect(
        Rect.fromLTWH(x, size.height - h, w, h),
        (i >= loIdx && i <= hiIdx) ? inPaint : outPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DayHistogramPainter old) =>
      old.loIdx != loIdx ||
      old.hiIdx != hiIdx ||
      old.inColor != inColor ||
      !listEquals(old.counts, counts);
}
