import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/screens/location_picker_screen.dart';
import 'package:narcis_nadzorniki/screens/type_selection_screen.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class FormScreen extends StatefulWidget {
  const FormScreen({
    super.key,
    required this.initialLocation,
    required this.initialObservers,
    required this.mapCenter,
  });

  final LatLng? initialLocation;
  final List<String> initialObservers;
  final LatLng mapCenter;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _observerController = TextEditingController();
  final _proposedTypeController = TextEditingController();
  final _locationService = LocationService();
  final _uuid = const Uuid();
  final _imagePicker = ImagePicker();

  LatLng? _location;
  String _accuracy = 'Natančna';
  DateTime _date = DateTime.now();
  TimeOfDay _time = TimeOfDay.now();
  List<SelectedDisturbanceType> _types = [];
  List<String> _photoPaths = [];
  List<String> _observers = [];
  String _actionTaken = 'Brez ukrepanja';
  bool _pickedOnMap = false;

  @override
  void initState() {
    super.initState();
    _location = widget.initialLocation;
    _observers = [...widget.initialObservers];
    _ensureLocation();
  }

  Future<void> _ensureLocation() async {
    if (_location != null) {
      return;
    }
    final location = await _locationService.getCurrentLocation();
    if (!mounted) {
      return;
    }
    setState(() {
      _location = location;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) {
      setState(() {
        _time = picked;
      });
    }
  }

  Future<void> _pickLocation() async {
    final initial = _pickedOnMap && _location != null ? _location! : widget.mapCenter;
    final selected = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(initialLocation: initial),
      ),
    );
    if (selected != null) {
      setState(() {
        _location = selected;
        _accuracy = 'Približna';
        _pickedOnMap = true;
      });
    }
  }

  Future<void> _selectTypes() async {
    final updated = await Navigator.of(context).push<List<SelectedDisturbanceType>>(
      MaterialPageRoute(
        builder: (_) => TypeSelectionScreen(initialSelections: _types),
      ),
    );
    if (updated != null) {
      setState(() {
        _types = updated;
      });
    }
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (_photoPaths.length >= 3) {
      _showSnack('Največ 3 fotografije na zapis.');
      return;
    }
    final picked = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() {
        _photoPaths = [..._photoPaths, picked.path];
      });
    }
  }

  void _showPhotoPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Uporabi kamero'),
                onTap: () {
                  Navigator.of(context).pop();
                  _addPhoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Izberi iz galerije'),
                onTap: () {
                  Navigator.of(context).pop();
                  _addPhoto(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _removePhoto(String path) {
    setState(() {
      _photoPaths = _photoPaths.where((item) => item != path).toList();
    });
  }

  void _addObserver() {
    final name = _observerController.text.trim();
    if (name.isEmpty) {
      return;
    }
    setState(() {
      _observers = [..._observers, name];
      _observerController.clear();
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_location == null) {
      _showSnack('Izberi lokacijo.');
      return;
    }
    if (_types.isEmpty) {
      _showSnack('Izberi vsaj en tip motnje.');
      return;
    }

    final observedAt = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _time.hour,
      _time.minute,
    );

    final record = Disturbance(
      id: _uuid.v4(),
      latitude: _location!.latitude,
      longitude: _location!.longitude,
      locationAccuracy: _accuracy,
      observedAt: observedAt,
      types: _types,
      description: _descriptionController.text.trim(),
      photoPaths: _photoPaths,
      observers: _observers,
      actionTaken: _actionTaken,
      pendingSync: true,
      createdAt: DateTime.now(),
      proposedType: _proposedTypeController.text.trim().isEmpty
          ? null
          : _proposedTypeController.text.trim(),
    );

    await context.read<AppState>().addRecord(record);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _observerController.dispose();
    _proposedTypeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy');
    final timeText = _time.format(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nov zapis'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Lokacija', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_location == null)
              const Text('Lokacija še ni nastavljena.')
            else
              Text(
                '${_location!.latitude.toStringAsFixed(5)}, ${_location!.longitude.toStringAsFixed(5)}',
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ensureLocation,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Uporabi GPS'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickLocation,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Izberi na karti'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _accuracy,
              decoration: const InputDecoration(labelText: 'Natančnost lokacije'),
              items: const [
                DropdownMenuItem(value: 'Natančna', child: Text('Natančna')),
                DropdownMenuItem(value: 'Približna', child: Text('Približna')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _accuracy = value;
                  });
                }
              },
            ),
            const Divider(height: 32),
            Text('Datum in čas', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickDate,
                    child: Text(dateFormat.format(_date)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickTime,
                    child: Text(timeText),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('Tip motnje', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_types.isEmpty) const Text('Ni izbranih tipov.'),
            if (_types.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _types
                    .map((type) => Chip(label: Text(type.display)))
                    .toList(),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _selectTypes,
              icon: const Icon(Icons.list_alt),
              label: const Text('Izberi tipe'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _proposedTypeController,
              decoration: const InputDecoration(
                labelText: 'Predlagaj nov tip (neobvezno)',
              ),
            ),
            const Divider(height: 32),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Opis',
                alignLabelWithHint: true,
              ),
              maxLines: 4,
            ),
            const Divider(height: 32),
            Text('Fotografije (max 3)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_photoPaths.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _photoPaths
                    .map(
                      (path) => Stack(
                        alignment: Alignment.topRight,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(path),
                              width: 90,
                              height: 90,
                              fit: BoxFit.cover,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () => _removePhoto(path),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              )
            else
              const Text('Ni dodanih fotografij.'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _showPhotoPicker,
              icon: const Icon(Icons.add_a_photo),
              label: const Text('Dodaj fotografijo'),
            ),
            const Divider(height: 32),
            Text('Opazovalci', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_observers.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _observers
                    .map(
                      (observer) => Chip(
                        label: Text(observer),
                        onDeleted: () {
                          setState(() {
                            _observers = _observers.where((item) => item != observer).toList();
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _observerController,
                    decoration: const InputDecoration(
                      labelText: 'Dodaj opazovalca',
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _addObserver,
                  icon: const Icon(Icons.person_add),
                ),
              ],
            ),
            const Divider(height: 32),
            DropdownButtonFormField<String>(
              value: _actionTaken,
              decoration: const InputDecoration(labelText: 'Ukrepanje'),
              items: const [
                DropdownMenuItem(value: 'Brez ukrepanja', child: Text('Brez ukrepanja')),
                DropdownMenuItem(value: 'Ustno opozorilo', child: Text('Ustno opozorilo')),
                DropdownMenuItem(value: 'Pisno opozorilo', child: Text('Pisno opozorilo')),
                DropdownMenuItem(value: 'Drugo', child: Text('Drugo')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _actionTaken = value;
                  });
                }
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Shrani zapis'),
            ),
          ],
        ),
      ),
    );
  }
}
