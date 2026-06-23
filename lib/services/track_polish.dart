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

/// Split the drawn track into separate polylines wherever two consecutive
/// kept fixes are more than this far apart, in metres. A continuously tracked
/// walk sampled at distanceFilter = 5 m never legitimately jumps this far
/// between stored points — even a 130 km/h drive samples at ~36 m steps at
/// 1 Hz. A jump this large means missing data: a stretch driven under the old
/// speed filter (rejected fixes), or a GPS dropout. Drawing one straight line
/// across that gap is the "spike" artefact; splitting leaves an honest hole
/// instead (TB-22).
const double kTrackGapSplitMeters = 200;

/// Cleans a recorded walk track into one or more polylines for display only.
///
/// 1. Drops fixes whose reported accuracy is worse than [maxAccuracyMeters].
///    Points with no accuracy are kept — the OS not reporting a value isn't
///    evidence the fix is bad.
/// 2. Splits the survivors wherever two consecutive ones jump more than
///    [maxGapMeters] apart (a driven stretch or a GPS dropout), so the gap is
///    left as a break between segments instead of a straight bridging line.
/// 3. Applies a centred moving average within each segment to damp jitter.
///
/// Pure and side-effect free. The raw points are untouched (they're write-once
/// on the server and stay the honest record); this only changes how the track
/// is drawn, so the thresholds are safe to tune later. Returns one list per
/// contiguous segment; a segment may come back with a single coordinate, so
/// callers drawing a [Polyline] should skip segments shorter than two points.
List<List<LatLng>> polishTrackSegments(
  List<WalkPoint> points, {
  double maxAccuracyMeters = kTrackAccuracyCeilingMeters,
  int smoothingWindow = kTrackSmoothingWindow,
  double maxGapMeters = kTrackGapSplitMeters,
}) {
  final kept = <WalkPoint>[
    for (final p in points)
      if (p.accuracy == null || p.accuracy! <= maxAccuracyMeters) p,
  ];
  if (kept.isEmpty) return const [];

  const distance = Distance();
  final runs = <List<WalkPoint>>[
    [kept.first],
  ];
  for (var i = 1; i < kept.length; i++) {
    if (distance(kept[i - 1].location, kept[i].location) > maxGapMeters) {
      runs.add(<WalkPoint>[]);
    }
    runs.last.add(kept[i]);
  }
  return [for (final run in runs) _smooth(run, smoothingWindow)];
}

/// Single-polyline variant: [polishTrackSegments] with gap-splitting disabled,
/// flattened to one coordinate list. Used by the unit tests and any caller
/// that wants the smoothed survivors without segmenting.
List<LatLng> polishTrack(
  List<WalkPoint> points, {
  double maxAccuracyMeters = kTrackAccuracyCeilingMeters,
  int smoothingWindow = kTrackSmoothingWindow,
}) =>
    [
      for (final segment in polishTrackSegments(
        points,
        maxAccuracyMeters: maxAccuracyMeters,
        smoothingWindow: smoothingWindow,
        maxGapMeters: double.infinity,
      ))
        ...segment,
    ];

/// Centred moving average over one contiguous run; returns the points
/// un-smoothed when there are too few to average.
List<LatLng> _smooth(List<WalkPoint> kept, int smoothingWindow) {
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
