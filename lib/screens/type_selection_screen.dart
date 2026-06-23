import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/disturbance_group_colors.dart';
import 'package:narcis_nadzorniki/data/disturbance_type_search.dart';
import 'package:narcis_nadzorniki/data/disturbance_types.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

String _selectionKey(DisturbanceTypeGroup group, DisturbanceType type) =>
    '${group.code}_${type.code}';

SelectedDisturbanceType _selectionFor(
  DisturbanceTypeGroup group,
  DisturbanceType type,
) =>
    SelectedDisturbanceType(
      groupCode: group.code,
      groupName: group.name,
      typeCode: type.code,
      typeName: type.name,
    );

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
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final type in widget.initialSelections)
        '${type.groupCode}_${type.typeCode}': type,
    };
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onTypeChanged(String key, SelectedDisturbanceType? selection) {
    setState(() {
      if (selection == null) {
        _selected.remove(key);
      } else {
        _selected[key] = selection;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isSearching = _query.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Izberi tipe motenj'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_selected.values.toList()),
              icon: const Icon(Icons.check, size: 20),
              label: Text(
                _selected.isEmpty ? 'Končaj' : 'Končaj (${_selected.length})',
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Išči tip motnje…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Počisti',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child:
                  isSearching ? _buildSearchResults(context) : _buildGroupedList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: disturbanceTypeGroups.length,
      itemBuilder: (context, index) {
        final group = disturbanceTypeGroups[index];
        return _TypeGroupTile(
          group: group,
          selected: _selected,
          onChanged: _onTypeChanged,
        );
      },
    );
  }

  Widget _buildSearchResults(BuildContext context) {
    final matches = searchDisturbanceTypes(_query);
    if (matches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Ni zadetkov za »${_query.trim()}«.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final match = matches[index];
        final group = match.group;
        final type = match.type;
        final hue = disturbanceGroupColor(group.code);
        final key = _selectionKey(group, type);
        return CheckboxListTile(
          value: _selected.containsKey(key),
          activeColor: hue,
          onChanged: (value) => _onTypeChanged(
            key,
            value == true ? _selectionFor(group, type) : null,
          ),
          title: Text('${type.code}. ${type.name}'),
          subtitle: Text(
            group.name,
            style: TextStyle(color: hue, fontWeight: FontWeight.w600),
          ),
        );
      },
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
            final key = _selectionKey(group, type);
            return CheckboxListTile(
              value: selected.containsKey(key),
              activeColor: hue,
              onChanged: (value) =>
                  onChanged(key, value == true ? _selectionFor(group, type) : null),
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
