// Helpers for the fixed option lists stored as string lists: TB-42's impacts
// on a record and TB-43's means of transport on a walk.

/// A JSON list of strings, tolerant of absence and of anything that is not a
/// string (dropped). Older local stores and servers older than narcis-vibed
/// NV-615 do not carry these lists; both read as empty, "not stated".
List<String> readStringList(Object? raw) =>
    raw is List ? raw.whereType<String>().toList() : const [];

/// Tick or untick [value] in [current]. The result is in [order]'s order,
/// with values outside [order] last as they were, so a stored list reads the
/// same whatever order the chips were tapped in. Ticking one of [exclusive]
/// drops the others (TB-42: a breach is established or suspected, not both).
List<String> toggleInOrder(
  List<String> current,
  String value,
  List<String> order, {
  List<String> exclusive = const [],
}) {
  if (current.contains(value)) {
    return [for (final v in current) if (v != value) v];
  }
  final drop = exclusive.contains(value)
      ? exclusive.where((v) => v != value).toSet()
      : const <String>{};
  final next = [
    for (final v in current) if (!drop.contains(v)) v,
    value,
  ];
  int rank(String v) {
    final i = order.indexOf(v);
    return i == -1 ? order.length : i;
  }

  // A stable sort: values outside [order] share one rank and keep their order.
  final indexed = [for (var i = 0; i < next.length; i++) (i, next[i])];
  indexed.sort((a, b) {
    final r = rank(a.$2).compareTo(rank(b.$2));
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
