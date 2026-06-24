import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';

Disturbance _rec({required DateTime observedAt, String? createdBy}) {
  return Disturbance(
    id: 'id-${observedAt.microsecondsSinceEpoch}-${createdBy ?? 'me'}',
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: observedAt,
    types: const [],
    description: '',
    photos: const [],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: 'Odprto',
    pendingSync: false,
    createdAt: observedAt,
    createdBy: createdBy,
  );
}

void main() {
  final now = DateTime(2026, 6, 24, 12);
  DateTime daysAgo(int d) => now.subtract(Duration(days: d));

  group('ageBucketOf (TB-6)', () {
    test('≤31 days is recent (boundary inclusive)', () {
      expect(ageBucketOf(daysAgo(0), now: now), AgeBucket.recent);
      expect(ageBucketOf(daysAgo(31), now: now), AgeBucket.recent);
    });
    test('32–365 days is mid (both boundaries)', () {
      expect(ageBucketOf(daysAgo(32), now: now), AgeBucket.mid);
      expect(ageBucketOf(daysAgo(365), now: now), AgeBucket.mid);
    });
    test('>365 days is old', () {
      expect(ageBucketOf(daysAgo(366), now: now), AgeBucket.old);
      expect(ageBucketOf(daysAgo(1000), now: now), AgeBucket.old);
    });
  });

  group('MotnjeFilter.unfiltered', () {
    test('is inactive and matches every record', () {
      const f = MotnjeFilter.unfiltered();
      expect(f.isActive, isFalse);
      expect(f.matches(_rec(observedAt: daysAgo(0)), now: now), isTrue);
      expect(f.matches(_rec(observedAt: daysAgo(500)), now: now), isTrue);
    });
  });

  group('age dimension', () {
    test('only-recent excludes mid and old; isActive', () {
      const f = MotnjeFilter(ageBuckets: {AgeBucket.recent});
      expect(f.isActive, isTrue);
      expect(f.matches(_rec(observedAt: daysAgo(10)), now: now), isTrue);
      expect(f.matches(_rec(observedAt: daysAgo(100)), now: now), isFalse);
      expect(f.matches(_rec(observedAt: daysAgo(700)), now: now), isFalse);
    });
    test('empty bucket set matches nothing', () {
      const f = MotnjeFilter(ageBuckets: {});
      expect(f.matches(_rec(observedAt: daysAgo(0)), now: now), isFalse);
    });
  });

  group('author dimension', () {
    test('empty authors means any author', () {
      const f = MotnjeFilter.unfiltered();
      expect(
        f.matches(_rec(observedAt: now, createdBy: 'a@gov.si'),
            currentUserEmail: 'me@gov.si', now: now),
        isTrue,
      );
    });
    test('specific author includes only that author (case-insensitive)', () {
      const f = MotnjeFilter(authors: {'a@gov.si'});
      expect(f.isActive, isTrue);
      expect(f.matches(_rec(observedAt: now, createdBy: 'A@gov.si'), now: now),
          isTrue);
      expect(f.matches(_rec(observedAt: now, createdBy: 'b@gov.si'), now: now),
          isFalse);
    });
    test('null createdBy folds into the current user', () {
      const f = MotnjeFilter(authors: {'me@gov.si'});
      expect(
        f.matches(_rec(observedAt: now, createdBy: null),
            currentUserEmail: 'me@gov.si', now: now),
        isTrue,
      );
      expect(
        f.matches(_rec(observedAt: now, createdBy: null),
            currentUserEmail: 'other@gov.si', now: now),
        isFalse,
      );
    });
  });

  group('date-window dimension', () {
    final from = DateTime(2025, 5, 1);
    final to = DateTime(2025, 5, 31, 23, 59, 59);
    final f = MotnjeFilter(from: from, to: to);
    test('isActive when a bound is set', () {
      expect(f.isActive, isTrue);
    });
    test('inside the window matches; boundaries inclusive', () {
      expect(
          f.matches(_rec(observedAt: DateTime(2025, 5, 15)), now: now), isTrue);
      expect(f.matches(_rec(observedAt: from), now: now), isTrue);
      expect(f.matches(_rec(observedAt: to), now: now), isTrue);
    });
    test('outside the window is excluded', () {
      expect(
          f.matches(_rec(observedAt: DateTime(2025, 4, 30)), now: now), isFalse);
      expect(
          f.matches(_rec(observedAt: DateTime(2025, 6, 1)), now: now), isFalse);
    });
  });

  group('dimensions compose with AND', () {
    test('a record must pass age AND author AND date', () {
      final f = MotnjeFilter(
        ageBuckets: const {AgeBucket.old},
        authors: const {'me@gov.si'},
        from: DateTime(2025, 1, 1),
        to: DateTime(2025, 12, 31, 23, 59, 59),
      );
      final pass = _rec(observedAt: DateTime(2025, 2, 1), createdBy: 'me@gov.si');
      expect(f.matches(pass, now: now, currentUserEmail: 'me@gov.si'), isTrue);
      final wrongAuthor =
          _rec(observedAt: DateTime(2025, 2, 1), createdBy: 'x@gov.si');
      expect(f.matches(wrongAuthor, now: now, currentUserEmail: 'me@gov.si'),
          isFalse);
    });
  });

  group('authorsIn', () {
    test('distinct, current user first, folds null createdBy, then alpha', () {
      final records = [
        _rec(observedAt: now, createdBy: 'zoe@gov.si'),
        _rec(observedAt: now, createdBy: null), // → me
        _rec(observedAt: now, createdBy: 'Ana@gov.si'),
        _rec(observedAt: now, createdBy: 'zoe@gov.si'), // dup
      ];
      expect(authorsIn(records, 'Me@gov.si'),
          ['me@gov.si', 'ana@gov.si', 'zoe@gov.si']);
    });
  });

  group('observedSpan', () {
    test('null for empty', () {
      expect(observedSpan(const []), isNull);
    });
    test('min and max observedAt', () {
      final span = observedSpan([
        _rec(observedAt: DateTime(2025, 3, 10)),
        _rec(observedAt: DateTime(2026, 1, 5)),
        _rec(observedAt: DateTime(2025, 8, 20)),
      ]);
      expect(span!.$1, DateTime(2025, 3, 10));
      expect(span.$2, DateTime(2026, 1, 5));
    });
  });
}
