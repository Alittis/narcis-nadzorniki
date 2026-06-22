import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:path_provider/path_provider.dart';

/// Top-level entry point for the background isolate. flutter_foreground_task
/// requires the entry point to be top-level + `@pragma('vm:entry-point')`
/// so the AOT compiler keeps it.
@pragma('vm:entry-point')
void walkStartCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(WalkTaskHandler());
}

/// Walk-tracking task that lives in a separate Dart isolate tied to the
/// flutter_foreground_task FGS. The main isolate (AppState) writes the
/// initial active-walk metadata to `active_walk.json` and starts this
/// service; the handler then owns the GPS subscription, applies the tick
/// filter, persists each accepted point back to that same file, and pings
/// the main isolate via SendPort so the UI can mirror progress live.
///
/// Why a separate isolate: Samsung One UI's "Freecess" mechanism freezes
/// the main app process aggressively. A geolocator stream subscribed from
/// the main isolate dies the moment the screen turns off; the FGS isolate
/// here is what's keeping the location stream alive.
class WalkTaskHandler extends TaskHandler {
  static const _activeFile = 'active_walk.json';

  // Filter thresholds — same values as the previous in-main-isolate filter.
  // OS-cached "phantom" fixes after a screen-off resume tend to fail on
  // staleness (>30 s) or accuracy (>50 m); teleport catches the rare case
  // where two real fixes are spaced wrongly by a hardware glitch.
  static const double _maxAccuracyMeters = 50;
  static const double _maxSpeedMps = 8;
  static const Duration _maxFixAge = Duration(seconds: 30);

  StreamSubscription<Position>? _positionSub;
  Walk? _walk;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _walk = await _loadActive();
    if (_walk == null) {
      sendPort?.send({'type': 'log', 'message': 'no active walk to resume'});
      return;
    }
    sendPort?.send({
      'type': 'log',
      'message': 'walk handler started (id=${_walk!.id}, '
          '${_walk!.points.length} buffered points)',
    });
    _startStream(sendPort);
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    // Position deliveries are handled via the stream; nothing to do here.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await _positionSub?.cancel();
    _positionSub = null;
    sendPort?.send({'type': 'log', 'message': 'walk handler destroyed'});
  }

  @override
  void onNotificationButtonPressed(String id) {}

  void _startStream(SendPort? sendPort) {
    // bestForNavigation asks for the tightest continuous fix the platform can
    // give while moving (on iOS it forces the navigation GNSS mode). On Android
    // it still rides the fused provider, so it's a nudge, not a cure for a
    // phone that drops to coarse/network location — the render-time accuracy
    // filter (track_polish.dart) is what actually defends the drawn track (TB-3).
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(
      (position) => _onTick(position, sendPort),
      onError: (Object e, StackTrace _) {
        sendPort?.send({'type': 'log', 'message': 'stream error: $e'});
      },
      onDone: () {
        sendPort?.send({'type': 'log', 'message': 'stream closed'});
      },
    );
  }

  Future<void> _onTick(Position pos, SendPort? sendPort) async {
    final walk = _walk;
    if (walk == null) return;

    final now = DateTime.now();
    final fixAge = now.difference(pos.timestamp);
    if (fixAge > _maxFixAge) {
      sendPort?.send({
        'type': 'log',
        'message': 'reject: stale fix (${fixAge.inSeconds}s old)',
      });
      return;
    }
    if (pos.accuracy > _maxAccuracyMeters) {
      sendPort?.send({
        'type': 'log',
        'message': 'reject: poor accuracy (${pos.accuracy.toStringAsFixed(0)} m)',
      });
      return;
    }
    if (walk.points.isNotEmpty) {
      final prev = walk.points.last;
      final dtSec =
          pos.timestamp.difference(prev.timestamp).inMilliseconds / 1000;
      if (dtSec > 0) {
        final meters = _haversineMeters(
          prev.latitude,
          prev.longitude,
          pos.latitude,
          pos.longitude,
        );
        final mps = meters / dtSec;
        if (mps > _maxSpeedMps) {
          sendPort?.send({
            'type': 'log',
            'message': 'reject: teleport (${mps.toStringAsFixed(1)} m/s)',
          });
          return;
        }
      }
    }

    final point = WalkPoint(
      seq: walk.points.length,
      latitude: pos.latitude,
      longitude: pos.longitude,
      timestamp: pos.timestamp,
      accuracy: pos.accuracy,
    );
    final updated = walk.copyWith(
      endedAt: point.timestamp,
      points: [...walk.points, point],
    );
    _walk = updated;
    await _saveActive(updated);
    sendPort?.send({'type': 'tick', 'point': point.toJson()});
  }

  Future<Walk?> _loadActive() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      return Walk.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveActive(Walk walk) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(walk.toJson()));
    await tmp.rename(file.path);
  }

  Future<File> _file() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_activeFile');
  }

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    double toRad(double d) => d * math.pi / 180.0;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }
}
