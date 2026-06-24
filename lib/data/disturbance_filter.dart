import 'package:narcis_nadzorniki/models/disturbance.dart';

/// How old a disturbance is, bucketed for the home-map marker colour and the
/// Motnje age filter (TB-6). Thresholds match the legend the warden sees:
/// [AgeBucket.recent] → red, [AgeBucket.mid] → orange, [AgeBucket.old] → blue.
enum AgeBucket { recent, mid, old }

const Set<AgeBucket> allAgeBuckets = {
  AgeBucket.recent,
  AgeBucket.mid,
  AgeBucket.old,
};

/// ≤ 31 days → [AgeBucket.recent], ≤ 365 days → [AgeBucket.mid], older → old.
/// [now] is injectable for deterministic tests; defaults to the wall clock.
AgeBucket ageBucketOf(DateTime observedAt, {DateTime? now}) {
  final days = (now ?? DateTime.now()).difference(observedAt).inDays;
  if (days <= 31) return AgeBucket.recent;
  if (days <= 365) return AgeBucket.mid;
  return AgeBucket.old;
}

/// Visibility filter for the home-map Motnje layer (TB-6). Three independent
/// dimensions composed with AND — age bucket, author, and an observed-date
/// window. [MotnjeFilter.unfiltered] shows everything. Immutable: the picker
/// sheet emits a fresh instance on every change.
class MotnjeFilter {
  const MotnjeFilter({
    this.ageBuckets = allAgeBuckets,
    this.authors = const {},
    this.groups,
    this.from,
    this.to,
  });

  const MotnjeFilter.unfiltered() : this();

  /// Age buckets to show. Empty shows none (unchecking all hides the layer).
  final Set<AgeBucket> ageBuckets;

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
      ageBuckets.length < allAgeBuckets.length ||
      authors.isNotEmpty ||
      groups != null ||
      from != null ||
      to != null;

  /// Whether [record] passes every active dimension. [currentUserEmail] is the
  /// author of records whose `createdBy` is still null (local, un-pushed — the
  /// caller is the author by definition).
  bool matches(
    Disturbance record, {
    DateTime? now,
    String? currentUserEmail,
  }) {
    if (!ageBuckets.contains(ageBucketOf(record.observedAt, now: now))) {
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
