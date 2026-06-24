import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/data/obmocja_store.dart';

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
const String _userAgent = 'si.terenska.beleznica';

// GURS public WMS (kataster nepremičnin / real-estate cadaster), CC BY 4.0.
// The PARCELE layer publishes two single-purpose styles; we stack them so
// the user gets both boundaries and labels. Server enforces its own scale
// gates: boundaries visible 1:50 → 1:10 000 (≈ z16+), labels visible
// 1:50 → 1:5 000 (≈ z17+). The TileLayer minZooms match those gates so
// we don't ship requests the server would answer with a blank PNG.
const String _gursParceleWmsBase =
    'https://ipi.eprostor.gov.si/wms-si-gurs-kn/ows?';
const String _gursParceleLayer = 'SI.GURS.KN:PARCELE';

/// Translucent overlay of Slovenian cadastral parcels: green polygon
/// outlines at z ≥ 16, parcel-number labels at z ≥ 17.
List<Widget> parceleOverlayTileLayers() {
  return [
    TileLayer(
      wmsOptions: WMSTileLayerOptions(
        baseUrl: _gursParceleWmsBase,
        layers: const [_gursParceleLayer],
        styles: const ['nep_kn_parcele'],
        format: 'image/png',
        transparent: true,
        version: '1.3.0',
      ),
      minZoom: 16,
      maxZoom: 19,
      userAgentPackageName: _userAgent,
    ),
    TileLayer(
      wmsOptions: WMSTileLayerOptions(
        baseUrl: _gursParceleWmsBase,
        layers: const [_gursParceleLayer],
        styles: const ['nep_kn_parcele_lbl'],
        format: 'image/png',
        transparent: true,
        version: '1.3.0',
      ),
      minZoom: 17,
      maxZoom: 19,
      userAgentPackageName: _userAgent,
    ),
  ];
}

// NarcIS production GeoServer (public WMS). The "Območja s statusom" layers
// live in the SI.NARCIS workspace, rendered with GeoServer's own published
// styles (STYLES empty). Tiles load per-viewport — instant first paint, and it
// scales to any sublayer because the server rasterises. Layer names + ordering
// are in obmocja_store.dart (zosWmsLayers / zosOrder).
const String _narcisOwsBase = 'https://narcis.gov.si/ows/ows?';

/// Protected-area ("Območja s statusom") overlay as server-styled WMS tiles for
/// the [active] sublayers, stacked into one request (polygons under points,
/// flagship layers under the rest). Tap-to-identify is handled separately via
/// GeoServer GetFeatureInfo (see `ObmocjaStore.identify`).
List<Widget> obmocjaWmsLayers(Set<ZosKind> active) {
  final names = <String>[];
  for (final k in zosOrder) {
    if (active.contains(k)) names.addAll(zosWmsLayers[k]!);
  }
  if (names.isEmpty) return const [];
  return [
    TileLayer(
      wmsOptions: WMSTileLayerOptions(
        baseUrl: _narcisOwsBase,
        layers: names,
        format: 'image/png',
        transparent: true,
        version: '1.3.0',
      ),
      maxZoom: 19,
      userAgentPackageName: _userAgent,
    ),
  ];
}

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

/// Translucent blue halo (radius in metres, so it scales with zoom). Shared
/// style for the user-accuracy circle and the Območja identify buffer.
CircleMarker _haloCircle(LatLng point, double radiusMeters) {
  return CircleMarker(
    point: point,
    radius: radiusMeters,
    useRadiusInMeter: true,
    color: Colors.blueAccent.withValues(alpha: 0.15),
    borderColor: Colors.blueAccent.withValues(alpha: 0.4),
    borderStrokeWidth: 1,
  );
}

/// Halo whose radius equals the OS-reported horizontal accuracy in metres —
/// same behaviour as Google Maps' blue accuracy circle.
CircleLayer userAccuracyCircleLayer(LatLng point, double accuracyMeters) {
  return CircleLayer(circles: [_haloCircle(point, accuracyMeters)]);
}

/// Same halo style, drawn at the last Območja tap to show the identify search
/// radius (the GetFeatureInfo buffer). Radius from `ObmocjaStore.bufferRadiusMeters`.
CircleLayer obmocjaBufferCircleLayer(LatLng point, double radiusMeters) {
  return CircleLayer(circles: [_haloCircle(point, radiusMeters)]);
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

/// Age-based fill colour for a disturbance marker, keyed off the same
/// [AgeBucket] thresholds the Motnje age filter uses (TB-6) so the map legend
/// and the filter always agree. red = recent · orange = mid · blue = old.
Color recordMarkerColorForAge(DateTime observedAt) {
  switch (ageBucketOf(observedAt)) {
    case AgeBucket.recent:
      return Colors.red;
    case AgeBucket.mid:
      return Colors.orange;
    case AgeBucket.old:
      return Colors.blue;
  }
}

/// Tap-target diameter for record markers on the home map. The visible disc is
/// far smaller — [RecordMarker]/[LegacyRecordMarker] `Center` an ~11–18 px dot,
/// so the rest of this box is invisible tappable margin, making an isolated
/// marker easy to hit (TB-19). 44 matches the walk-detail map and sits just
/// under Material's 48 dp minimum: deliberately not larger, to limit how much
/// overlapping hit-boxes steal each other's taps in dense clusters.
const double kRecordMarkerTapDiameter = 44;

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
        width: 18,
        height: 18,
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
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
          alignment: Alignment.center,
          child: isMine
              ? null
              : Container(
                  width: 7,
                  height: 7,
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
        width: 11,
        height: 11,
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
          width: 8,
          height: 8,
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
