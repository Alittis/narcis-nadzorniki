import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/disturbance_group_colors.dart';
import 'package:narcis_nadzorniki/data/disturbance_types.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

class TypeSelectionScreen extends StatefulWidget {
  const TypeSelectionScreen({
    super.key,
    required this.initialSelections,
  });

  final List<SelectedDisturbanceType> initialSelections;

  @override
  State<TypeSelectionScreen> createState() => _TypeSelectionScreenState();
}

class _TypeSelectionScreenState extends State<TypeSelectionScreen> {
  late final Map<String, SelectedDisturbanceType> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final type in widget.initialSelections)
        '${type.groupCode}_${type.typeCode}': type,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Izberi tipe motenj'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected.values.toList()),
            child: const Text('Končaj'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: disturbanceTypeGroups.length,
          itemBuilder: (context, index) {
            final group = disturbanceTypeGroups[index];
            return _TypeGroupTile(
              group: group,
              selected: _selected,
              onChanged: (key, selection) {
                setState(() {
                  if (selection == null) {
                    _selected.remove(key);
                  } else {
                    _selected[key] = selection;
                  }
                });
              },
            );
          },
        ),
      ),
    );
  }
}

class _TypeGroupTile extends StatelessWidget {
  const _TypeGroupTile({
    required this.group,
    required this.selected,
    required this.onChanged,
  });

  final DisturbanceTypeGroup group;
  final Map<String, SelectedDisturbanceType> selected;
  final void Function(String key, SelectedDisturbanceType? selection) onChanged;

  @override
  Widget build(BuildContext context) {
    final hue = disturbanceGroupColor(group.code);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: hue, width: 4),
          ),
        ),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.fromLTRB(12, 4, 16, 4),
          leading: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: disturbanceGroupTint(group.code),
              shape: BoxShape.circle,
            ),
            child: Text(
              group.code,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: hue,
              ),
            ),
          ),
          title: Text(
            group.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          children: group.types.map((type) {
            final key = '${group.code}_${type.code}';
            final isSelected = selected.containsKey(key);
            return CheckboxListTile(
              value: isSelected,
              activeColor: hue,
              onChanged: (value) {
                if (value == true) {
                  onChanged(
                    key,
                    SelectedDisturbanceType(
                      groupCode: group.code,
                      groupName: group.name,
                      typeCode: type.code,
                      typeName: type.name,
                    ),
                  );
                } else {
                  onChanged(key, null);
                }
              },
              title: Text('${type.code}. ${type.name}'),
              subtitle: type.note == null
                  ? null
                  : Text(
                      type.note!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
