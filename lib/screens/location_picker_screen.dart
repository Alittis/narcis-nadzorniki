import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({
    super.key,
    required this.initialLocation,
  });

  final LatLng initialLocation;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapController = MapController();
  final _locationService = LocationService();
  late LatLng _selected;
  LatLng? _userLocation;
  BasemapMode _basemapMode = BasemapMode.osm;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialLocation;
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
      _mapController.move(location, _mapController.camera.zoom);
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
          initialZoom: 14,
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
              if (_userLocation != null)
                Marker(
                  point: _userLocation!,
                  width: 40,
                  height: 40,
                  child: const Icon(
                    Icons.my_location,
                    color: Colors.blueAccent,
                    size: 26,
                  ),
                ),
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
      floatingActionButton: FloatingActionButton(
        onPressed: _locating ? null : () => _refreshUserLocation(recenter: true),
        tooltip: 'Moja lokacija',
        child: _locating
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.my_location),
      ),
    );
  }
}
