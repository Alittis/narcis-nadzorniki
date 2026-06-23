import 'package:narcis_nadzorniki/data/disturbance_types.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';

/// A single flat search hit: the matched [type] together with the [group] it
/// belongs to. The group is needed to disambiguate the per-group type code
/// (codes restart at `a` in every group) and to build the selection key.
typedef DisturbanceTypeMatch = ({DisturbanceTypeGroup group, DisturbanceType type});

/// Folds a string for accent- and case-insensitive matching: lower-cases and
/// strips the South-Slavic diacritics wardens won't type consistently
/// (č/ć→c, š→s, ž→z, đ→d). So "sneman" matches "Snemanje" and "sotor" matches
/// "Fotograf v maskirnem šotoru".
String foldForSearch(String input) {
  return input
      .toLowerCase()
      .replaceAll('č', 'c')
      .replaceAll('ć', 'c')
      .replaceAll('š', 's')
      .replaceAll('ž', 'z')
      .replaceAll('đ', 'd');
}

/// Returns the types whose name — or whose group's name — matches [query], in
/// codebook order. A group-name match pulls in every type of that group (so
/// "kopal" surfaces the whole Kopalci group). Matching is accent- and
/// case-insensitive (see [foldForSearch]). An empty/whitespace query yields no
/// matches — callers show the full grouped browse view instead.
List<DisturbanceTypeMatch> searchDisturbanceTypes(
  String query, {
  List<DisturbanceTypeGroup> groups = disturbanceTypeGroups,
}) {
  final needle = foldForSearch(query.trim());
  if (needle.isEmpty) return const [];
  final matches = <DisturbanceTypeMatch>[];
  for (final group in groups) {
    final groupMatches = foldForSearch(group.name).contains(needle);
    for (final type in group.types) {
      if (groupMatches || foldForSearch(type.name).contains(needle)) {
        matches.add((group: group, type: type));
      }
    }
  }
  return matches;
}
