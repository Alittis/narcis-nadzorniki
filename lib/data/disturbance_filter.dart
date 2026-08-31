import 'package:narcis_nadzorniki/models/disturbance.dart';

/// The four review states `TB_MOTNJE.STATUS_OBRAVNAVE` allows (DB CHECK
/// `ck_tb_motnje_stat`, mirrored by the create form's dropdown). Insertion
/// order is display order — open → in progress → closed → handed off — and
/// `Set` literals preserve it, so the filter sheet iterates this directly.
const Set<String> allCaseStatuses = {
  'Odprto',
  'V obravnavi',
  'Zaključeno',
  'Predano drugi službi',
};

/// Visibility filter for the home-map Motnje layer (TB-6). Four independent
/// dimensions composed with AND — case status (TB-27), author, category
/// (TB-18) and an observed-date window. [MotnjeFilter.unfiltered] shows
/// everything. Immutable: the picker sheet emits a fresh instance on every
/// change.
///
/// The age-bucket dimension was removed in TB-29: it existed to mirror the
/// map's age colouring, and once TB-27 made the dots encode status instead,
/// three coarse buckets were strictly worse than the [from]/[to] window that
/// already sits beside them.
class MotnjeFilter {
  const MotnjeFilter({
    this.statuses = allCaseStatuses,
    this.authors = const {},
    this.groups,
    this.from,
    this.to,
  });

  const MotnjeFilter.unfiltered() : this();

  /// Case-review states to show (TB-27) — the dimension the marker colour
  /// encodes. Empty shows none (unchecking all hides the layer).
  final Set<String> statuses;

  /// Lower-cased author emails to show; empty means "any author".
  final Set<String> authors;

  /// Disturbance group (category) codes to show. **null** = any category (no
  /// restriction); a set restricts to those groups (a record matches when any
  /// of its types is in one); an **empty** set shows none. (Nullable so the
  /// picker's "Vse kategorije" can toggle all-on ↔ all-off, which an
  /// empty-means-any scheme couldn't express.)
  final Set<String>? groups;

  /// Inclusive lower / upper bounds on `observedAt`; null = unbounded on that
  /// side. A null pair means no date window.
  final DateTime? from;
  final DateTime? to;

  /// True when any dimension is narrower than "show everything" — drives the
  /// Filter chip's active state.
  bool get isActive =>
      statuses.length < allCaseStatuses.length ||
      authors.isNotEmpty ||
      groups != null ||
      from != null ||
      to != null;

  /// Whether [record] passes every active dimension. [currentUserEmail] is the
  /// author of records whose `createdBy` is still null (local, un-pushed — the
  /// caller is the author by definition).
  bool matches(
    Disturbance record, {
    String? currentUserEmail,
  }) {
    // A status outside [allCaseStatuses] — one added server-side after this
    // build ships — is never hidden by this dimension. It still draws, in the
    // web's unknown-status gray; silently vanishing off the map would be a far
    // worse way to learn the vocabulary grew.
    if (allCaseStatuses.contains(record.caseStatus) &&
        !statuses.contains(record.caseStatus)) {
      return false;
    }
    if (authors.isNotEmpty) {
      final key = authorKey(record, currentUserEmail);
      if (key == null || !authors.contains(key)) return false;
    }
    if (groups != null &&
        !record.types.any((t) => groups!.contains(t.groupCode))) {
      return false;
    }
    final at = record.observedAt;
    if (from != null && at.isBefore(from!)) return false;
    if (to != null && at.isAfter(to!)) return false;
    return true;
  }
}

/// Lower-cased author key for [record]; a null `createdBy` (local-only record)
/// folds into [currentUserEmail] — the caller is the author by definition.
String? authorKey(Disturbance record, String? currentUserEmail) {
  final raw = record.createdBy ?? currentUserEmail;
  return raw?.toLowerCase();
}

/// Distinct author keys across [records] (see [authorKey]), the current user
/// sorted first, then alphabetically.
List<String> authorsIn(List<Disturbance> records, String? currentUserEmail) {
  final me = currentUserEmail?.toLowerCase();
  final keys = <String>{};
  for (final r in records) {
    final k = authorKey(r, currentUserEmail);
    if (k != null) keys.add(k);
  }
  return keys.toList()
    ..sort((a, b) {
      if (a == me) return -1;
      if (b == me) return 1;
      return a.compareTo(b);
    });
}

/// Earliest and latest `observedAt` across [records], or null when empty.
(DateTime, DateTime)? observedSpan(List<Disturbance> records) {
  if (records.isEmpty) return null;
  var min = records.first.observedAt;
  var max = min;
  for (final r in records) {
    if (r.observedAt.isBefore(min)) min = r.observedAt;
    if (r.observedAt.isAfter(max)) max = r.observedAt;
  }
  return (min, max);
}

/// Distinct (groupCode, groupName) pairs across all records' selected types,
/// ordered by numeric group code (matching the codebook order). Drives the
/// category filter's option list — only categories actually present are shown.
List<(String code, String name)> groupsIn(List<Disturbance> records) {
  final byCode = <String, String>{};
  for (final r in records) {
    for (final t in r.types) {
      byCode.putIfAbsent(t.groupCode, () => t.groupName);
    }
  }
  final entries = byCode.entries.toList()
    ..sort((a, b) {
      final ai = int.tryParse(a.key);
      final bi = int.tryParse(b.key);
      if (ai != null && bi != null) return ai.compareTo(bi);
      return a.key.compareTo(b.key);
    });
  return [for (final e in entries) (e.key, e.value)];
}
