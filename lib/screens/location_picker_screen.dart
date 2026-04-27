import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({
    super.key,
    required this.initialLocation,
    required this.initialBasemap,
  });

  final LatLng initialLocation;
  final BasemapMode initialBasemap;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapController = MapController();
  final _locationService = LocationService();
  late LatLng _selected;
  late BasemapMode _basemapMode;
  LatLng? _userLocation;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialLocation;
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
            onPressed: () => Navigator.of(context).pop(_selected),
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
            });
          },
        ),
        children: [
          ...basemapTileLayers(_basemapMode),
          MarkerLayer(
            markers: [
              if (_userLocation != null) userLocationMarker(_userLocation!),
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
            ],
          ),
        ],
      ),
      floatingActionButton: LocateButton(
        locating: _locating,
        onTap: _locating ? null : () => _refreshUserLocation(recenter: true),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}
