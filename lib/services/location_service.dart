import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class UserPosition {
  const UserPosition({required this.location, required this.accuracy});

  final LatLng location;
  // Horizontal accuracy in meters as reported by the OS. Used to render
  // the accuracy halo around the user dot.
  final double accuracy;
}

class LocationService {
  /// One-shot fetch returning the current LatLng. Existing callers that
  /// don't need the accuracy keep using this.
  Future<LatLng?> getCurrentLocation() async {
    final position = await getCurrentPosition();
    return position?.location;
  }

  /// One-shot fetch with accuracy. Used by the home map to size the halo.
  Future<UserPosition?> getCurrentPosition() async {
    if (!await _ensurePermission()) return null;
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    return UserPosition(
      location: LatLng(position.latitude, position.longitude),
      accuracy: position.accuracy,
    );
  }

  /// Continuous stream of the device location while in foreground. The
  /// 5 m distance filter trims battery draw and notify churn — the dot
  /// only repaints when the user has actually moved a perceptible amount.
  /// Without ACCESS_BACKGROUND_LOCATION (which we don't request from this
  /// stream), the OS pauses delivery when the app is backgrounded and
  /// resumes on foreground. Walk-around recording uses a separate isolate
  /// (see `walk_task_handler.dart`) tied to a flutter_foreground_task FGS
  /// for true background tracking.
  /// Caller is responsible for ensuring permission is granted first
  /// (typically by calling `getCurrentPosition` once at startup) — calling
  /// `requestPermission` concurrently with another call can race.
  Stream<UserPosition> watchPosition() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).map(
      (p) => UserPosition(
        location: LatLng(p.latitude, p.longitude),
        accuracy: p.accuracy,
      ),
    );
  }

  Future<bool> _ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }
}
