import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

enum BasemapMode { osm, satellite }

const String _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _esriImageryUrl =
    'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const String _esriLabelsUrl =
    'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';
const String _userAgent = 'si.narcis.nadzorniki';

List<Widget> basemapTileLayers(BasemapMode mode) {
  switch (mode) {
    case BasemapMode.osm:
      return [
        TileLayer(
          urlTemplate: _osmTileUrl,
          userAgentPackageName: _userAgent,
          maxZoom: 19,
          maxNativeZoom: 19,
        ),
      ];
    case BasemapMode.satellite:
      return [
        TileLayer(
          urlTemplate: _esriImageryUrl,
          userAgentPackageName: _userAgent,
          maxZoom: 19,
          maxNativeZoom: 19,
        ),
        TileLayer(
          urlTemplate: _esriLabelsUrl,
          userAgentPackageName: _userAgent,
          maxZoom: 19,
          maxNativeZoom: 19,
        ),
      ];
  }
}

class BasemapToggleButton extends StatelessWidget {
  const BasemapToggleButton({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final BasemapMode mode;
  final ValueChanged<BasemapMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final isSatellite = mode == BasemapMode.satellite;
    return IconButton(
      tooltip: isSatellite ? 'Zemljevid' : 'Satelitska slika',
      icon: Icon(isSatellite ? Icons.map_rounded : Icons.satellite_alt_rounded),
      onPressed: () => onChanged(
        isSatellite ? BasemapMode.osm : BasemapMode.satellite,
      ),
    );
  }
}
