// Unit tests for polishTrack — the render-time accuracy filter + smoothing
// applied to walk tracks before they're drawn (TB-3). Pure function, no I/O.

import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/track_polish.dart';

WalkPoint _p(double lat, double lon, {double? acc, int seq = 0}) => WalkPoint(
      seq: seq,
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026, 1, 1),
      accuracy: acc,
    );

void main() {
  group('polishTrack accuracy filter', () {
    test('drops fixes worse than the ceiling, keeps the rest', () {
      final out = polishTrack(
        [_p(0, 0, acc: 5), _p(0, 1, acc: 50), _p(0, 2, acc: 10)],
        smoothingWindow: 1, // disable smoothing to assert on the filter alone
      );
      expect(out.length, 2);
      expect(out[0].longitude, 0);
      expect(out[1].longitude, 2); // the 50 m fix in the middle is gone
    });

    test('keeps points with no reported accuracy', () {
      final out = polishTrack(
        [_p(0, 0), _p(0, 1, acc: 100), _p(0, 2)],
        smoothingWindow: 1,
      );
      expect(out.map((p) => p.longitude), [0, 2]);
    });

    test('honours a custom ceiling', () {
      expect(polishTrack([_p(0, 0, acc: 25)]), isEmpty); // default 20 m drops it
      expect(
        polishTrack([_p(0, 0, acc: 25)], maxAccuracyMeters: 30),
        hasLength(1),
      );
    });

    test('empty in, empty out', () {
      expect(polishTrack(const []), isEmpty);
    });
  });

  group('polishTrack smoothing', () {
    test('returns survivors un-smoothed when fewer than 3 remain', () {
      final out = polishTrack([_p(0, 0, acc: 5), _p(0, 10, acc: 5)]);
      expect(out.length, 2);
      expect(out[1].longitude, 10); // not averaged toward its neighbour
    });

    test('damps a single lateral spike toward its neighbours', () {
      final out = polishTrack(
        [
          _p(0, 0, acc: 5),
          _p(0, 1, acc: 5),
          _p(0.001, 2, acc: 5), // a fix kicked sideways off the line
          _p(0, 3, acc: 5),
          _p(0, 4, acc: 5),
        ],
        smoothingWindow: 3,
      );
      expect(out.length, 5);
      // The spike's latitude is pulled back from 0.001 toward 0.
      expect(out[2].latitude, closeTo(0.001 / 3, 1e-9));
      expect(out[2].latitude, lessThan(0.001));
    });

    test('preserves point count for a clean track', () {
      final pts = [for (var i = 0; i < 10; i++) _p(0, i.toDouble(), acc: 5)];
      expect(polishTrack(pts).length, 10);
    });
  });
}
