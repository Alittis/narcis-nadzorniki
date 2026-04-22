import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
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
  late LatLng _selected;
  BasemapMode _basemapMode = BasemapMode.osm;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialLocation;
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
        options: MapOptions(
          initialCenter: _selected,
          initialZoom: 14,
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
    );
  }
}
