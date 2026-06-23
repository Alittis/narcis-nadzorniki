import 'package:flutter_test/flutter_test.dart';
import 'package:narcis_nadzorniki/data/disturbance_type_search.dart';
import 'package:narcis_nadzorniki/data/disturbance_types.dart';

void main() {
  group('foldForSearch', () {
    test('lower-cases input', () {
      expect(foldForSearch('Snemanje'), 'snemanje');
    });

    test('strips South-Slavic diacritics', () {
      expect(foldForSearch('Č ć Š ž Đ'), 'c c s z d');
      expect(foldForSearch('ŠOTOR'), 'sotor');
    });
  });

  group('searchDisturbanceTypes', () {
    test('empty or whitespace query returns no matches', () {
      expect(searchDisturbanceTypes(''), isEmpty);
      expect(searchDisturbanceTypes('   '), isEmpty);
    });

    test('gibberish query returns no matches', () {
      expect(searchDisturbanceTypes('zzqxwk'), isEmpty);
    });

    test('matches a type name case-insensitively', () {
      final hits = searchDisturbanceTypes('sneman');
      expect(hits, isNotEmpty);
      expect(hits.any((m) => m.type.name.startsWith('Snemanje')), isTrue);
    });

    test('matches a type name with the accent dropped', () {
      // "Fotograf v maskirnem šotoru" — typed without the š.
      final hits = searchDisturbanceTypes('sotor');
      expect(hits.any((m) => m.type.name.contains('šotoru')), isTrue);
    });

    test('a group-name match pulls in every type of that group', () {
      final sprehajalci =
          disturbanceTypeGroups.firstWhere((g) => g.name == 'Sprehajalci');
      final groupHits = searchDisturbanceTypes('sprehajalci')
          .where((m) => m.group.code == sprehajalci.code)
          .toList();
      // Includes types whose own name does NOT contain the needle.
      expect(groupHits.length, sprehajalci.types.length);
      expect(groupHits.any((m) => m.type.name == 'Fotograf'), isTrue);
    });

    test('every hit matches on type name or group name', () {
      const needle = 'kopal';
      for (final m in searchDisturbanceTypes(needle)) {
        expect(
          foldForSearch(m.type.name).contains(needle) ||
              foldForSearch(m.group.name).contains(needle),
          isTrue,
        );
      }
    });

    test('matches are returned in codebook order', () {
      final hits = searchDisturbanceTypes('drugo');
      final order = [for (final m in hits) disturbanceTypeGroups.indexOf(m.group)];
      expect(order, [...order]..sort());
    });
  });
}
