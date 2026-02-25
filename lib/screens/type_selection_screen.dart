import 'package:flutter/material.dart';
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
      body: ListView.builder(
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Text('${group.code}. ${group.name}'),
        children: group.types.map((type) {
          final key = '${group.code}_${type.code}';
          final isSelected = selected.containsKey(key);
          return CheckboxListTile(
            value: isSelected,
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
    );
  }
}
