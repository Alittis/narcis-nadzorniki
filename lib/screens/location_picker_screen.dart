import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/hotspot.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

/// What *Potrdi* returns: the record's location and, TB-39, the hot spot it is
/// filed on (null = none).
class LocationPick {
  const LocationPick(this.location, this.hotspotId);

  final LatLng location;
  final String? hotspotId;
}

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({
    super.key,
    required this.initialLocation,
    required this.initialBasemap,
    this.hotspots = const [],
    this.initialHotspotId,
  });

  final LatLng initialLocation;
  final BasemapMode initialBasemap;

  /// TB-39: the org's hot spots, drawn as diamonds. TB-64 (owner,
  /// 2026-11-26): a hot spot is a location choice like any point on the map. A
  /// tap on one puts the record on it and links it; a tap anywhere else puts the
  /// record there and drops the link; a second tap on the chosen one, or
  /// *Odstrani*, drops the link and leaves the location where it is.
  final List<Hotspot> hotspots;
  final String? initialHotspotId;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapController = MapController();
  final _locationService = LocationService();
  late LatLng _selected;
  late BasemapMode _basemapMode;
  String? _hotspotId;
  LatLng? _userLocation;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialLocation;
    _hotspotId = widget.initialHotspotId;
    _basemapMode = widget.initialBasemap;
    _refreshUserLocation(recenter: false);
  }

  Future<void> _refreshUserLocation({required bool recenter}) async {
    setState(() => _locating = true);
    final location = await _locationService.getCurrentLocation();
    if (!mounted) {
      return;
    }
    setState(() {
      _locating = false;
      if (location != null) {
        _userLocation = location;
      }
    });
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GPS lokacije ni mogoče pridobiti.')),
      );
      return;
    }
    if (recenter) {
      // Match the home screen: keep the user's manual zoom but lift to
      // kUserZoom only if they're zoomed out below it.
      final currentZoom = _mapController.camera.zoom;
      final targetZoom = currentZoom < kUserZoom ? kUserZoom : currentZoom;
      _mapController.move(location, targetZoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Izberi lokacijo'),
        actions: [
          BasemapToggleButton(
            mode: _basemapMode,
            onChanged: (mode) => setState(() => _basemapMode = mode),
          ),
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(LocationPick(_selected, _hotspotId)),
            child: const Text('Potrdi'),
          ),
        ],
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _selected,
          initialZoom: kUserZoom,
          maxZoom: kMapMaxZoom,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onTap: (tapPosition, point) {
            setState(() {
              _selected = point;
              // TB-64: the record is somewhere else, so on no hot spot.
              _hotspotId = null;
            });
          },
        ),
        children: [
          ...basemapTileLayers(_basemapMode),
          MarkerLayer(
            markers: [
              if (_userLocation != null) userLocationMarker(_userLocation!),
              // TB-64: on a hot spot, its ringed diamond marks the location;
              // the pin stays when that hot spot is not drawn (not on this
              // device's list), so the location is always marked.
              if (_hotspotOf(_hotspotId) == null)
                Marker(
                  point: _selected,
                  width: 44,
                  height: 44,
                  child: const Icon(
                    Icons.location_on,
                    color: Colors.red,
                    size: 40,
                  ),
                ),
              // Last, so on top: the warden usually stands at the hot spot,
              // and the pin or the blue dot drawn over it would take the tap.
              for (final h in widget.hotspots)
                Marker(
                  point: LatLng(h.latitude, h.longitude),
                  width: kRecordMarkerTapDiameter,
                  height: kRecordMarkerTapDiameter,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      if (_hotspotId == h.id) {
                        _hotspotId = null;
                      } else {
                        // TB-64: the hot spot is the record's location.
                        _hotspotId = h.id;
                        _selected = LatLng(h.latitude, h.longitude);
                      }
                    }),
                    child: HotspotMarker(selected: _hotspotId == h.id),
                  ),
                ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: widget.hotspots.isEmpty && _hotspotId == null
          ? null
          : _HotspotBar(
              hotspot: _hotspotOf(_hotspotId),
              attached: _hotspotId != null,
              onRemove: () => setState(() => _hotspotId = null),
            ),
      floatingActionButton: LocateButton(
        locating: _locating,
        onTap: _locating ? null : () => _refreshUserLocation(recenter: true),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }

  Hotspot? _hotspotOf(String? id) {
    for (final h in widget.hotspots) {
      if (h.id == id) return h;
    }
    return null;
  }
}

/// TB-39: under the map, the hot spot the record is filed on with a way to
/// take it off, or how to choose one. Adds the gesture inset itself
/// (ARCHITECTURE §15, pattern 1b).
class _HotspotBar extends StatelessWidget {
  const _HotspotBar({
    required this.hotspot,
    required this.attached,
    required this.onRemove,
  });

  final Hotspot? hotspot;
  final bool attached;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Material(
      color: colors.surface,
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 8, 10 + bottomInset),
        // One height with and without the Odstrani button, so the map above
        // does not jump when a hot spot is attached.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: HotspotMarker(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: attached
                    ? Text(
                        'Vroča točka: ${hotspot?.name ?? 'ni na seznamu'}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      )
                    : Text(
                        'Tapni vročo točko, da zapis postaviš nanjo.',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
              ),
              if (attached)
                TextButton(onPressed: onRemove, child: const Text('Odstrani')),
            ],
          ),
        ),
      ),
    );
  }
}
