import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_filter.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

SelectedDisturbanceType _type(String groupCode, String groupName) =>
    SelectedDisturbanceType(
      groupCode: groupCode,
      groupName: groupName,
      typeCode: 'a',
      typeName: 'x',
    );

Disturbance _rec({
  required DateTime observedAt,
  String? createdBy,
  List<SelectedDisturbanceType> types = const [],
  String caseStatus = 'Odprto',
}) {
  return Disturbance(
    id: 'id-${observedAt.microsecondsSinceEpoch}-${createdBy ?? 'me'}',
    latitude: 45.79,
    longitude: 14.36,
    locationAccuracy: 'Natančna',
    observedAt: observedAt,
    types: types,
    description: '',
    photos: const [],
    observers: const [],
    actionTaken: 'Brez ukrepa',
    caseStatus: caseStatus,
    pendingSync: false,
    createdAt: observedAt,
    createdBy: createdBy,
  );
}

void main() {
  final now = DateTime(2026, 6, 24, 12);
  DateTime daysAgo(int d) => now.subtract(Duration(days: d));

  group('MotnjeFilter.unfiltered', () {
    test('is inactive and matches every record', () {
      const f = MotnjeFilter.unfiltered();
      expect(f.isActive, isFalse);
      expect(f.matches(_rec(observedAt: daysAgo(0))), isTrue);
      expect(f.matches(_rec(observedAt: daysAgo(500))), isTrue);
    });
  });

  group('author dimension', () {
    test('empty authors means any author', () {
      const f = MotnjeFilter.unfiltered();
      expect(
        f.matches(_rec(observedAt: now, createdBy: 'a@gov.si'),
            currentUserEmail: 'me@gov.si'),
        isTrue,
      );
    });
    test('specific author includes only that author (case-insensitive)', () {
      const f = MotnjeFilter(authors: {'a@gov.si'});
      expect(f.isActive, isTrue);
      expect(f.matches(_rec(observedAt: now, createdBy: 'A@gov.si')),
          isTrue);
      expect(f.matches(_rec(observedAt: now, createdBy: 'b@gov.si')),
          isFalse);
    });
    test('null createdBy folds into the current user', () {
      const f = MotnjeFilter(authors: {'me@gov.si'});
      expect(
        f.matches(_rec(observedAt: now, createdBy: null),
            currentUserEmail: 'me@gov.si'),
        isTrue,
      );
      expect(
        f.matches(_rec(observedAt: now, createdBy: null),
            currentUserEmail: 'other@gov.si'),
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
          f.matches(_rec(observedAt: DateTime(2025, 5, 15))), isTrue);
      expect(f.matches(_rec(observedAt: from)), isTrue);
      expect(f.matches(_rec(observedAt: to)), isTrue);
    });
    test('outside the window is excluded', () {
      expect(
          f.matches(_rec(observedAt: DateTime(2025, 4, 30))), isFalse);
      expect(
          f.matches(_rec(observedAt: DateTime(2025, 6, 1))), isFalse);
    });
  });

  group('dimensions compose with AND', () {
    test('a record must pass status AND author AND date', () {
      final f = MotnjeFilter(
        statuses: const {'Odprto'},
        authors: const {'me@gov.si'},
        from: DateTime(2025, 1, 1),
        to: DateTime(2025, 12, 31, 23, 59, 59),
      );
      final pass = _rec(observedAt: DateTime(2025, 2, 1), createdBy: 'me@gov.si');
      expect(f.matches(pass, currentUserEmail: 'me@gov.si'), isTrue);
      final wrongAuthor =
          _rec(observedAt: DateTime(2025, 2, 1), createdBy: 'x@gov.si');
      expect(f.matches(wrongAuthor, currentUserEmail: 'me@gov.si'),
          isFalse);
    });
  });

  group('category (group) dimension', () {
    final rec1 = _rec(observedAt: now, types: [_type('1', 'Sprehajalci')]);
    final rec4 = _rec(observedAt: now, types: [_type('4', 'Vožnja v naravi')]);
    final recMulti = _rec(
      observedAt: now,
      types: [_type('1', 'Sprehajalci'), _type('4', 'Vožnja v naravi')],
    );
    test('null groups (unfiltered) means any category', () {
      const f = MotnjeFilter.unfiltered();
      expect(f.isActive, isFalse);
      expect(f.matches(rec1), isTrue);
      expect(f.matches(rec4), isTrue);
    });
    test('an empty (non-null) group set shows none', () {
      const f = MotnjeFilter(groups: {});
      expect(f.isActive, isTrue);
      expect(f.matches(rec1), isFalse);
      expect(f.matches(rec4), isFalse);
    });
    test('a selected group includes only records with a type in it', () {
      const f = MotnjeFilter(groups: {'1'});
      expect(f.isActive, isTrue);
      expect(f.matches(rec1), isTrue);
      expect(f.matches(rec4), isFalse);
      expect(f.matches(recMulti), isTrue); // any type in group → match
    });
    test('multiple selected groups OR within the dimension', () {
      const f = MotnjeFilter(groups: {'1', '4'});
      expect(f.matches(rec1), isTrue);
      expect(f.matches(rec4), isTrue);
      expect(
        f.matches(_rec(observedAt: now, types: [_type('2', 'Kopalci')])),
        isFalse,
      );
    });
  });

  group('groupsIn', () {
    test('distinct present (code,name) pairs, ordered by numeric code', () {
      final records = [
        _rec(observedAt: now, types: [_type('10', 'Deset')]),
        _rec(observedAt: now, types: [_type('2', 'Dve'), _type('1', 'Ena')]),
        _rec(observedAt: now, types: [_type('2', 'Dve')]),
      ];
      expect(groupsIn(records), [('1', 'Ena'), ('2', 'Dve'), ('10', 'Deset')]);
    });
    test('empty when no records', () {
      expect(groupsIn(const []), isEmpty);
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

  group('status dimension (TB-27)', () {
    test('default filter shows every status and stays inactive', () {
      const f = MotnjeFilter.unfiltered();
      expect(f.isActive, isFalse);
      for (final status in allCaseStatuses) {
        expect(f.matches(_rec(observedAt: now, caseStatus: status)),
            isTrue,
            reason: status);
      }
    });

    test('unticking a status hides only that status, and marks active', () {
      final f = MotnjeFilter(
        statuses: {...allCaseStatuses}..remove('Zaključeno'),
      );
      expect(f.isActive, isTrue);
      expect(
          f.matches(_rec(observedAt: now, caseStatus: 'Zaključeno')),
          isFalse);
      expect(f.matches(_rec(observedAt: now, caseStatus: 'Odprto')),
          isTrue);
    });

    test('empty status set hides everything, like an empty age set', () {
      const f = MotnjeFilter(statuses: {});
      expect(f.matches(_rec(observedAt: now, caseStatus: 'Odprto')),
          isFalse);
    });

    test('a status this build does not know is never hidden', () {
      // If the back office grows a fifth state, records carrying it must keep
      // drawing (in gray) rather than silently vanishing off the map.
      final f = MotnjeFilter(statuses: {...allCaseStatuses}..remove('Odprto'));
      expect(
          f.matches(_rec(observedAt: now, caseStatus: 'V mediaciji')),
          isTrue);
    });

    test('composes with AND against the date window', () {
      final f = MotnjeFilter(
        statuses: const {'Odprto'},
        from: DateTime(2026, 6, 1),
      );
      expect(
          f.matches(_rec(observedAt: daysAgo(2), caseStatus: 'Odprto')),
          isTrue);
      // right status, outside the window
      expect(
          f.matches(_rec(observedAt: daysAgo(400), caseStatus: 'Odprto')),
          isFalse);
      // inside the window, wrong status
      expect(
          f.matches(_rec(observedAt: daysAgo(2), caseStatus: 'Zaključeno')),
          isFalse);
    });

    test('the four states match the DB CHECK vocabulary, in display order', () {
      expect(allCaseStatuses.toList(), [
        'Odprto',
        'V obravnavi',
        'Zaključeno',
        'Predano drugi službi',
      ]);
    });
  });
}
