import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

enum BasemapMode { osm, satellite }

/// Shared zoom rules for any FlutterMap in the app. Tile providers max out
/// at 19; user-recenter lifts to 14 only when the current zoom is below it
/// so a manual zoom-in is preserved.
const double kMapMaxZoom = 19.0;
const double kUserZoom = 14.0;

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

/// User's current GPS dot. Used by HomeScreen and LocationPickerScreen so
/// they render the same way.
Marker userLocationMarker(LatLng point) {
  return Marker(
    point: point,
    width: 24,
    height: 24,
    child: Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blueAccent,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
    ),
  );
}

/// "Recenter on me" button. Same look on every map screen — 48px circle,
/// elevated, navigation arrow rotated 45° clockwise; spinner while a GPS
/// resolve is in flight.
class LocateButton extends StatelessWidget {
  const LocateButton({
    super.key,
    required this.locating,
    required this.onTap,
  });

  final bool locating;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Transform.rotate(
                    angle: 0.785398, // 45° clockwise
                    child: const Icon(Icons.navigation),
                  ),
          ),
        ),
      ),
    );
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
