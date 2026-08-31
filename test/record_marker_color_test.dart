// TB-27: the map's disturbance dots encode *status obravnave*, and their colours
// are shared with the web backoffice. These tests pin the exact hex values so a
// drift from narcis-vibed `web/src/lib/trsca/format.ts` (STATUS_COLORS) fails
// here rather than showing up as two apps disagreeing about what a colour means.
//
// The age-colour counterpart was deleted in TB-29 along with the Starost filter.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';

void main() {
  group('recordMarkerColorForStatus (TB-27)', () {
    test('matches the web STATUS_COLORS palette exactly', () {
      expect(recordMarkerColorForStatus('Odprto'), const Color(0xFFD97706));
      expect(recordMarkerColorForStatus('V obravnavi'), const Color(0xFF0A84FF));
      expect(recordMarkerColorForStatus('Zaključeno'), const Color(0xFF1B7A1B));
      expect(recordMarkerColorForStatus('Predano drugi službi'),
          const Color(0xFF8E8E93));
    });

    test('every known status has a colour', () {
      for (final status in allCaseStatuses) {
        expect(() => recordMarkerColorForStatus(status), returnsNormally,
            reason: status);
      }
    });

    test('an unknown status falls back to gray, like the web', () {
      // Mirrors STATUS_COLORS[status] ?? "#8e8e93" — a status added server-side
      // after this build must still draw, not throw.
      expect(recordMarkerColorForStatus('V mediaciji'), const Color(0xFF8E8E93));
      expect(recordMarkerColorForStatus(''), const Color(0xFF8E8E93));
    });

    test('the four statuses are four distinct colours', () {
      // The dot colour is the only thing distinguishing them on the map, so a
      // copy-paste collision in the palette must fail here.
      final colors = {
        for (final s in allCaseStatuses) recordMarkerColorForStatus(s),
      };
      expect(colors, hasLength(allCaseStatuses.length));
    });
  });
}
