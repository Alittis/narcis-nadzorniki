import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/obmocje_sheet.dart' show zosTitle;

/// Layer picker for the "Območja s statusom" sublayers. Opened from the
/// "Območja" chip; toggling a row updates the active set live (the map redraws
/// behind the sheet) via [onChanged].
Future<void> showObmocjaPicker(
  BuildContext context, {
  required Set<ZosKind> active,
  required void Function(ZosKind kind, bool on) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ObmocjaPicker(active: active, onChanged: onChanged),
  );
}

class _ObmocjaPicker extends StatefulWidget {
  const _ObmocjaPicker({required this.active, required this.onChanged});

  final Set<ZosKind> active;
  final void Function(ZosKind kind, bool on) onChanged;

  @override
  State<_ObmocjaPicker> createState() => _ObmocjaPickerState();
}

class _ObmocjaPickerState extends State<_ObmocjaPicker> {
  late final Set<ZosKind> _local = {...widget.active};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
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
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.trailing,
                value: _local.contains(k),
                onChanged: (v) {
                  final on = v ?? false;
                  setState(() => on ? _local.add(k) : _local.remove(k));
                  widget.onChanged(k, on);
                },
                title: Text(zosTitle(k)),
              ),
          ],
        ),
      ),
    );
  }
}
