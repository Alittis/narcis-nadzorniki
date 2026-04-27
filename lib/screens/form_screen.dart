import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
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
    this.initialPhotoPath,
    this.initialTypes,
  });

  final LatLng? initialLocation;
  final List<String> initialObservers;
  final LatLng mapCenter;
  final String? initialPhotoPath;
  final List<SelectedDisturbanceType>? initialTypes;

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
  List<DisturbancePhoto> _photos = [];
  List<String> _observers = [];
  String _actionTaken = 'Brez ukrepanja';
  bool _pickedOnMap = false;

  @override
  void initState() {
    super.initState();
    _location = widget.initialLocation;
    _observers = [...widget.initialObservers];
    if (widget.initialTypes != null) {
      _types = [...widget.initialTypes!];
    }
    final photoPath = widget.initialPhotoPath;
    if (photoPath != null) {
      _photos = [
        DisturbancePhoto(
          id: _uuid.v4(),
          mimeType: 'image/jpeg',
          localPath: photoPath,
          pendingUpload: true,
        ),
      ];
    }
    _ensureLocation();
  }

  Future<void> _ensureLocation() async {
    if (_location != null) {
      return;
    }
    await _useFreshGps();
  }

  Future<void> _useFreshGps() async {
    final location = await _locationService.getCurrentLocation();
    if (!mounted) {
      return;
    }
    if (location == null) {
      _showSnack('GPS lokacije ni mogoče pridobiti.');
      return;
    }
    setState(() {
      _location = location;
      _accuracy = 'Natančna';
      _pickedOnMap = false;
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
    if (_photos.length >= 3) {
      _showSnack('Največ 3 fotografije na zapis.');
      return;
    }
    final picked = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked != null) {
      // Stable storage happens in AppState.addRecord; here we just hold the
      // temp path so the user can preview / remove before saving.
      setState(() {
        _photos = [
          ..._photos,
          DisturbancePhoto(
            id: _uuid.v4(),
            mimeType: 'image/jpeg',
            localPath: picked.path,
            pendingUpload: true,
          ),
        ];
      });
    }
  }

  void _showPhotoSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final atMax = _photos.length >= 3;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Fotografije',
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_photos.length}/3',
                          style: Theme.of(sheetContext).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_photos.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Ni dodanih fotografij.',
                          style: Theme.of(sheetContext).textTheme.bodyMedium,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: _photos.map((photo) {
                          final path = photo.localPath;
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: path != null
                                    ? Image.file(
                                        File(path),
                                        width: 92,
                                        height: 92,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        width: 92,
                                        height: 92,
                                        color: Colors.black12,
                                        child: const Icon(Icons.image_not_supported),
                                      ),
                              ),
                              Positioned(
                                top: -6,
                                right: -6,
                                child: InkWell(
                                  onTap: () {
                                    _removePhoto(photo);
                                    setSheetState(() {});
                                  },
                                  customBorder: const CircleBorder(),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.black87,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 16),
                    if (atMax)
                      Text(
                        'Doseženih največ 3 fotografij.',
                        style: Theme.of(sheetContext).textTheme.bodySmall,
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                Navigator.of(sheetContext).pop();
                                await _addPhoto(ImageSource.camera);
                              },
                              icon: const Icon(Icons.photo_camera),
                              label: const Text('Posnemi'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                Navigator.of(sheetContext).pop();
                                await _addPhoto(ImageSource.gallery);
                              },
                              icon: const Icon(Icons.photo_library),
                              label: const Text('Galerija'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _removePhoto(DisturbancePhoto photo) {
    setState(() {
      _photos = _photos.where((item) => item.id != photo.id).toList();
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
      photos: _photos,
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
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nov zapis'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _photoTile(colors)),
                  const SizedBox(width: 12),
                  Expanded(child: _typesTile(colors)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _section(
              colors: colors,
              icon: Icons.notes_rounded,
              title: 'Opis',
              child: TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  hintText: 'Neobvezno – kratek opis dogodka',
                  alignLabelWithHint: true,
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                ),
                minLines: 3,
                maxLines: 6,
              ),
            ),
            const SizedBox(height: 12),
            _section(
              colors: colors,
              icon: Icons.group_outlined,
              title: 'Dodatni opazovalci',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_observers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _observers
                            .map(
                              (observer) => Chip(
                                label: Text(observer),
                                onDeleted: () {
                                  setState(() {
                                    _observers = _observers
                                        .where((item) => item != observer)
                                        .toList();
                                  });
                                },
                              ),
                            )
                            .toList(),
                      ),
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
                      IconButton.filledTonal(
                        onPressed: _addObserver,
                        icon: const Icon(Icons.person_add_alt_1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _section(
              colors: colors,
              icon: Icons.gavel_rounded,
              title: 'Ukrepanje',
              child: DropdownButtonFormField<String>(
                value: _actionTaken,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
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
            ),
            const SizedBox(height: 12),
            _section(
              colors: colors,
              icon: Icons.tune_rounded,
              title: 'Podrobnosti zapisa',
              subtitle: 'Samodejno izpolnjeno – preveri in po potrebi popravi.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _subLabel('Lokacija', colors),
                  const SizedBox(height: 6),
                  if (_location == null)
                    Text(
                      'Lokacija še ni nastavljena.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    )
                  else
                    Text(
                      '${_location!.latitude.toStringAsFixed(5)}, ${_location!.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _useFreshGps,
                          icon: const Icon(Icons.my_location, size: 18),
                          label: const Text('GPS'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickLocation,
                          icon: const Icon(Icons.map_outlined, size: 18),
                          label: const Text('Karta'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _accuracy,
                    decoration: InputDecoration(
                      labelText: 'Natančnost lokacije',
                      filled: true,
                      fillColor: colors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                    ),
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
                  const SizedBox(height: 16),
                  _subLabel('Datum in čas', colors),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickDate,
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(dateFormat.format(_date)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickTime,
                          icon: const Icon(Icons.access_time, size: 16),
                          label: Text(timeText),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _proposedTypeController,
                    decoration: InputDecoration(
                      labelText: 'Predlagaj nov tip (neobvezno)',
                      filled: true,
                      fillColor: colors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Shrani zapis'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _section({
    required ColorScheme colors,
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _subLabel(String text, ColorScheme colors) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
    );
  }

  Widget _photoTile(ColorScheme colors) {
    final photo = _photos.isNotEmpty ? _photos.first : null;
    final hasPhoto = photo != null;
    final bg = hasPhoto ? colors.surfaceContainerHigh : colors.primaryContainer;
    final fg = colors.onPrimaryContainer;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: bg,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: _showPhotoSheet,
        child: AspectRatio(
          aspectRatio: 1,
          child: hasPhoto
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    if (photo.localPath != null)
                      Image.file(
                        File(photo.localPath!),
                        fit: BoxFit.cover,
                      )
                    else
                      Container(
                        color: Colors.black12,
                        child: const Icon(Icons.image_not_supported, size: 40),
                      ),
                    if (_photos.length > 1)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_photos.length}/3',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.edit_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_a_photo_outlined,
                        size: 44,
                        color: fg,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Dodaj foto',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _typesTile(ColorScheme colors) {
    final hasTypes = _types.isNotEmpty;
    const amberBg = Color(0xFFFFF4E0);
    const amberBorder = Color(0xFFFFB74D);
    const amberFg = Color(0xFFB85B00);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: hasTypes ? colors.surfaceContainerHigh : amberBg,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: hasTypes
              ? colors.outlineVariant.withValues(alpha: 0.5)
              : amberBorder,
          width: hasTypes ? 1 : 1.5,
        ),
      ),
      child: InkWell(
        onTap: _selectTypes,
        child: AspectRatio(
          aspectRatio: 1,
          child: hasTypes
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.list_alt_rounded, size: 16, color: colors.primary),
                          const SizedBox(width: 6),
                          Text(
                            'Tipi motnje',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.edit_rounded,
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: _types
                                .map(
                                  (type) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colors.primaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      type.display,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.onPrimaryContainer,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const Padding(
                  padding: EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.menu_book_rounded,
                        size: 44,
                        color: amberFg,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Izberi tipe motnje',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: amberFg,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
