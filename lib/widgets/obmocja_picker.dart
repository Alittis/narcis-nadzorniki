import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart' show zosTitle;

/// Layer picker for the "Območja s statusom" sublayers. Opened from the
/// "Območja" chip; every tap reports the whole active set to [onChanged], so
/// the map redraws behind the sheet (and the choice is saved) once per tap.
Future<void> showObmocjaPicker(
  BuildContext context, {
  required Set<ZosKind> active,
  required void Function(Set<ZosKind> active) onChanged,
}) {
  // Scroll-controlled: the default sheet stops at 9/16 of the screen, which
  // the rows outgrow (TB-37 overflowed it by 3 px on the A56); the scroll
  // view inside covers a screen too short for them.
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ObmocjaPicker(active: active, onChanged: onChanged),
  );
}

/// The parent row over [ZosKind.ns] and [ZosKind.zo] (TB-60). Natural
/// monuments are protected areas, so ticking it turns them on with the rest.
const String _zoGroupTitle = 'Zavarovana območja';

class _ObmocjaPicker extends StatefulWidget {
  const _ObmocjaPicker({required this.active, required this.onChanged});

  final Set<ZosKind> active;
  final void Function(Set<ZosKind> active) onChanged;

  @override
  State<_ObmocjaPicker> createState() => _ObmocjaPickerState();
}

class _ObmocjaPickerState extends State<_ObmocjaPicker> {
  late final Set<ZosKind> _local = {...widget.active};

  void _set(List<ZosKind> kinds, bool on) {
    setState(() {
      if (on) {
        _local.addAll(kinds);
      } else {
        _local.removeAll(kinds);
      }
    });
    widget.onChanged({..._local});
  }

  Widget _row(ZosKind k, {bool indented = false}) => CheckboxListTile(
        dense: true,
        controlAffinity: ListTileControlAffinity.trailing,
        contentPadding: indented
            ? const EdgeInsetsDirectional.only(start: 40, end: 24)
            : null,
        value: _local.contains(k),
        onChanged: (v) => _set([k], v ?? false),
        title: Text(zosTitle(k)),
      );

  @override
  Widget build(BuildContext context) {
    final zo = _local.contains(ZosKind.zo);
    final ns = _local.contains(ZosKind.ns);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Območja s statusom',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (final k in zosOrder)
              if (k == ZosKind.zo) ...[
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.trailing,
                  tristate: true,
                  value: zo && ns ? true : (zo || ns ? null : false),
                  // None or some → all; all → none.
                  onChanged: (_) =>
                      _set(const [ZosKind.zo, ZosKind.ns], !(zo && ns)),
                  title: const Text(_zoGroupTitle),
                ),
                _row(ZosKind.ns, indented: true),
                _row(ZosKind.zo, indented: true),
              ] else if (k != ZosKind.ns)
                _row(k),
          ],
        ),
      ),
    );
  }
}
