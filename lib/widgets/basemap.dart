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

/// Translucent halo whose radius equals the OS-reported horizontal
/// accuracy in metres. Sized in metres (not pixels) so it grows/shrinks
/// with zoom — same behaviour as Google Maps' blue accuracy circle.
CircleLayer userAccuracyCircleLayer(LatLng point, double accuracyMeters) {
  return CircleLayer(
    circles: [
      CircleMarker(
        point: point,
        radius: accuracyMeters,
        useRadiusInMeter: true,
        color: Colors.blueAccent.withValues(alpha: 0.15),
        borderColor: Colors.blueAccent.withValues(alpha: 0.4),
        borderStrokeWidth: 1,
      ),
    ],
  );
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

/// Age-based fill colour for a disturbance marker.
/// red ≤ 31 days · orange ≤ 365 days · blue older.
Color recordMarkerColorForAge(DateTime observedAt) {
  final age = DateTime.now().difference(observedAt).inDays;
  if (age <= 31) return Colors.red;
  if (age <= 365) return Colors.orange;
  return Colors.blue;
}

/// Disturbance-record marker. Filled disc = own record, ring = teammate's.
/// White halo + drop-shadow keep it legible on any basemap.
class RecordMarker extends StatelessWidget {
  const RecordMarker({super.key, required this.color, required this.isMine});

  final Color color;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 26,
        height: 26,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
          alignment: Alignment.center,
          child: isMine
              ? null
              : Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Smaller, deep-purple variant for legacy pre-app records. Same halo /
/// shadow treatment as [RecordMarker] for visual consistency.
class LegacyRecordMarker extends StatelessWidget {
  const LegacyRecordMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.deepPurple,
          ),
        ),
      ),
    );
  }
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
