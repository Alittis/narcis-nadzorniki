import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/walk.dart';

/// Render-time accuracy cap for a drawn walk track, in metres. Empirically
/// (TB-3, 2026-06-22, real walks pulled via ORDS) clean walks sit at a median
/// 4–8 m with p90 ≤ 10 m, while the pathological "scattered off the path"
/// walks ride 20–50 m for their whole length. A 20 m cut cleanly separates the
/// two populations — it drops ≈0 % of good fixes and the bulk of the bad ones.
const double kTrackAccuracyCeilingMeters = 20;

/// Centred moving-average window (odd) used to damp the residual GPS jitter
/// left on the surviving points. Deliberately small: enough to take the weave
/// out, gentle enough that it doesn't noticeably round real corners.
const int kTrackSmoothingWindow = 5;

/// Cleans a recorded walk track for display only.
///
/// 1. Drops fixes whose reported accuracy is worse than [maxAccuracyMeters].
///    Points with no accuracy are kept — the OS not reporting a value isn't
///    evidence the fix is bad.
/// 2. Applies a centred moving average over the survivors to damp jitter.
///
/// Pure and side-effect free. The raw points are untouched (they're write-once
/// on the server and stay the honest record); this only changes how the
/// polyline is drawn, so the thresholds are safe to tune later. Returns an
/// empty list when nothing survives, and the survivors un-smoothed when there
/// are too few to average.
List<LatLng> polishTrack(
  List<WalkPoint> points, {
  double maxAccuracyMeters = kTrackAccuracyCeilingMeters,
  int smoothingWindow = kTrackSmoothingWindow,
}) {
  final kept = <WalkPoint>[
    for (final p in points)
      if (p.accuracy == null || p.accuracy! <= maxAccuracyMeters) p,
  ];
  if (kept.length < 3 || smoothingWindow < 2) {
    return [for (final p in kept) p.location];
  }

  final half = smoothingWindow ~/ 2;
  final out = <LatLng>[];
  for (var i = 0; i < kept.length; i++) {
    final lo = (i - half) < 0 ? 0 : i - half;
    final hi = (i + half) >= kept.length ? kept.length - 1 : i + half;
    var sumLat = 0.0;
    var sumLon = 0.0;
    for (var j = lo; j <= hi; j++) {
      sumLat += kept[j].latitude;
      sumLon += kept[j].longitude;
    }
    final n = hi - lo + 1;
    out.add(LatLng(sumLat / n, sumLon / n));
  }
  return out;
}
