import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';

const _monthAbbrevSl = [
  'jan', 'feb', 'mar', 'apr', 'maj', 'jun', //
  'jul', 'avg', 'sep', 'okt', 'nov', 'dec',
];

String _monthLabel(DateTime m) =>
    "${_monthAbbrevSl[m.month - 1]} '${(m.year % 100).toString().padLeft(2, '0')}";

String _authorLabel(String key, String? me) {
  final local = key.contains('@') ? key.split('@').first : key;
  return key == me?.toLowerCase() ? '$local (jaz)' : local;
}

/// Filter picker for the home-map Motnje layer (TB-6). Opened from the "Filter"
/// chip; edits push live to [onChanged] so the map redraws behind the sheet,
/// matching the Območja picker. [records] is the full Motnje set (used to
/// derive the author list and date span), [filter] the current selection.
Future<void> showMotnjeFilterSheet(
  BuildContext context, {
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
      initial: filter,
      records: records,
      currentUserEmail: currentUserEmail,
      onChanged: onChanged,
    ),
  );
}

class _MotnjeFilterSheet extends StatefulWidget {
  const _MotnjeFilterSheet({
    required this.initial,
    required this.records,
    required this.currentUserEmail,
    required this.onChanged,
  });

  final MotnjeFilter initial;
  final List<Disturbance> records;
  final String? currentUserEmail;
  final void Function(MotnjeFilter) onChanged;

  @override
  State<_MotnjeFilterSheet> createState() => _MotnjeFilterSheetState();
}

class _MotnjeFilterSheetState extends State<_MotnjeFilterSheet> {
  late Set<AgeBucket> _buckets;
  late Set<String> _authors; // 0 or 1 element (single-select UI)
  late final List<String> _authorKeys;
  DateTime? _startMonth;
  late final int _monthCount;
  late RangeValues _months;

  @override
  void initState() {
    super.initState();
    _buckets = {...widget.initial.ageBuckets};
    _authors = {...widget.initial.authors};
    _authorKeys = authorsIn(widget.records, widget.currentUserEmail);

    final span = observedSpan(widget.records);
    if (span == null) {
      _monthCount = 0;
    } else {
      _startMonth = DateTime(span.$1.year, span.$1.month);
      _monthCount = (span.$2.year - _startMonth!.year) * 12 +
          (span.$2.month - _startMonth!.month);
    }
    // Reflect any incoming date window back onto the slider thumbs.
    var lo = 0, hi = _monthCount;
    if (_startMonth != null && widget.initial.from != null) {
      lo = _monthIndexOf(widget.initial.from!).clamp(0, _monthCount);
    }
    if (_startMonth != null && widget.initial.to != null) {
      hi = _monthIndexOf(widget.initial.to!).clamp(0, _monthCount);
    }
    _months = RangeValues(lo.toDouble(), hi.toDouble());
  }

  int _monthIndexOf(DateTime d) =>
      (d.year - _startMonth!.year) * 12 + (d.month - _startMonth!.month);

  DateTime _monthAt(int i) =>
      DateTime(_startMonth!.year, _startMonth!.month + i);

  // Inclusive last microsecond of month i.
  DateTime _monthEnd(int i) => DateTime(_startMonth!.year, _startMonth!.month + i + 1)
      .subtract(const Duration(microseconds: 1));

  bool get _dateActive =>
      _monthCount > 0 && (_months.start > 0 || _months.end < _monthCount);

  MotnjeFilter get _current => MotnjeFilter(
        ageBuckets: _buckets,
        authors: _authors,
        from: _dateActive ? _monthAt(_months.start.round()) : null,
        to: _dateActive ? _monthEnd(_months.end.round()) : null,
      );

  void _emit() => widget.onChanged(_current);

  void _reset() {
    setState(() {
      _buckets = {...allAgeBuckets};
      _authors = {};
      _months = RangeValues(0, _monthCount.toDouble());
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = _current;
    final shown = widget.records
        .where((r) => filter.matches(r, currentUserEmail: widget.currentUserEmail))
        .length;
    final selectedAuthor = _authors.isEmpty ? null : _authors.first;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
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
                        child: Text('Filter motenj',
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    'Prikazanih: $shown od ${widget.records.length}',
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
                    _authorRow(
                      key,
                      _authorLabel(key, widget.currentUserEmail),
                      selectedAuthor,
                    ),
                ],
                if (_monthCount > 0) ...[
                  const Divider(height: 8),
                  _sectionLabel('Obdobje'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_monthLabel(_monthAt(_months.start.round()))),
                        Text(_monthLabel(_monthAt(_months.end.round()))),
                      ],
                    ),
                  ),
                  RangeSlider(
                    values: _months,
                    min: 0,
                    max: _monthCount.toDouble(),
                    divisions: _monthCount,
                    labels: RangeLabels(
                      _monthLabel(_monthAt(_months.start.round())),
                      _monthLabel(_monthAt(_months.end.round())),
                    ),
                    onChanged: (v) => setState(() => _months = v),
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
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : Colors.black45,
      ),
      title: Text(label),
      onTap: () => _selectAuthor(key),
    );
  }
}
