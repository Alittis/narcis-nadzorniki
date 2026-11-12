import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One counted failure kind, as `POST /tezave` takes it (TB-59, narcis-racun
/// RN-22 S3): the phone-API path with its ids folded, the kind of failure, and
/// how often it happened since the last report. Nothing else — no record
/// contents, coordinates, photo data or text the person typed.
@immutable
class Tezava {
  const Tezava({required this.pot, required this.koda, required this.stevilo});

  final String pot;
  final String koda;
  final int stevilo;

  Map<String, dynamic> toJson() => {
    'pot': pot,
    'koda': koda,
    'stevilo': stevilo,
  };

  @override
  bool operator ==(Object other) =>
      other is Tezava &&
      other.pot == pot &&
      other.koda == koda &&
      other.stevilo == stevilo;

  @override
  int get hashCode => Object.hash(pot, koda, stevilo);

  @override
  String toString() => 'Tezava($pot, $koda, $stevilo)';
}

/// TB-59: the sync and upload failures a signed-in person hit, counted per
/// (`pot`, `koda`) until the server takes them.
///
/// Bounded whatever happens offline: at most [maxEntries] kinds (one report
/// carries them all) and each count stops at [maxCount] — the route's own
/// limits. A new kind beyond the cap is not counted.
///
/// The counts belong to the account that hit them. A failure counted for a
/// different account drops what an earlier one left, and [flush] for an account
/// that does not own the counts discards them unsent: they would otherwise be
/// filed under whoever signed in next.
///
/// One JSON file beside the record stores. Unreadable or unwritable, the counts
/// live in memory for this run only; nothing here ever throws to the caller.
class TezaveStore {
  TezaveStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  static const maxEntries = 50;
  static const maxCount = 1000;
  static final _pot = RegExp(r'^/[A-Za-z0-9/_:.[\]-]{0,199}$');
  static final _koda = RegExp(r'^[A-Za-z0-9_.:-]{1,60}$');
  static const _fileName = 'tezave.json';

  final Future<Directory> Function() _directory;

  // Insertion-ordered, keyed by "<pot> <koda>" (a space is in neither).
  final Map<String, Tezava> _counts = {};
  String? _account;
  Future<void> _writes = Future.value();
  bool _writeQueued = false;
  bool _flushing = false;

  /// What is counted now, in the order the kinds first occurred.
  List<Tezava> get pending => List.unmodifiable(_counts.values);

  /// Completes once what is counted now is on disk (or the write failed).
  Future<void> get saved => _writes;

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _counts.clear();
      _account = json['racun'] as String?;
      for (final e in json['tezave'] as List<dynamic>) {
        final m = e as Map<String, dynamic>;
        _add(m['pot'] as String, m['koda'] as String, m['stevilo'] as int);
      }
    } catch (_) {
      // A torn or foreign file: start empty rather than not at all.
      _counts.clear();
      _account = null;
    }
  }

  /// Counts one failure of kind [koda] on [pot] for [account]. A [pot] or
  /// [koda] the route would refuse is not counted, so it cannot block a report.
  void record({
    required String account,
    required String pot,
    required String koda,
  }) {
    if (!_pot.hasMatch(pot) || !_koda.hasMatch(koda)) return;
    final owner = account.trim().toLowerCase();
    if (_account != owner) {
      _counts.clear();
      _account = owner;
    }
    _add(pot, koda, 1);
    _save();
  }

  void _add(String pot, String koda, int by) {
    final key = '$pot $koda';
    final was = _counts[key];
    if (was == null && _counts.length >= maxEntries) return;
    final n = ((was?.stevilo ?? 0) + by).clamp(1, maxCount);
    _counts[key] = Tezava(pot: pot, koda: koda, stevilo: n);
  }

  /// Sends what is counted for [account] through [send], which completes only
  /// when the server took it (a 204) and throws otherwise. What was sent is
  /// then subtracted, so a failure counted while the report was in flight is
  /// kept for the next one; on a throw everything stays. One report at a time.
  /// Never throws.
  Future<void> flush(
    String account,
    Future<void> Function(List<Tezava> tezave) send,
  ) async {
    if (_flushing || _counts.isEmpty) return;
    if (_account != account.trim().toLowerCase()) {
      await clear();
      return;
    }
    _flushing = true;
    final sent = pending;
    try {
      await send(sent);
      for (final t in sent) {
        final key = '${t.pot} ${t.koda}';
        final left = (_counts[key]?.stevilo ?? 0) - t.stevilo;
        if (left > 0) {
          _counts[key] = Tezava(pot: t.pot, koda: t.koda, stevilo: left);
        } else {
          _counts.remove(key);
        }
      }
      debugPrint('[tezave] reported ${sent.length} kind(s)');
      _save();
    } catch (e) {
      debugPrint('[tezave] report not taken, ${sent.length} kind(s) kept: $e');
    } finally {
      _flushing = false;
    }
    await _writes;
  }

  /// Forgets every count (logout).
  Future<void> clear() async {
    _counts.clear();
    _account = null;
    _save();
    await _writes;
  }

  /// Writes are chained, so a later state never lands under an earlier one,
  /// and coalesced: a write still waiting takes the state as it is when it
  /// runs, so a burst of failures costs one write.
  void _save() {
    if (_writeQueued) return;
    _writeQueued = true;
    _writes = _writes.then((_) async {
      _writeQueued = false;
      final snapshot = _counts.isEmpty
          ? null
          : jsonEncode({
              'racun': _account,
              'tezave': [for (final t in _counts.values) t.toJson()],
            });
      try {
        final file = await _file();
        if (snapshot == null) {
          if (await file.exists()) await file.delete();
        } else {
          await file.writeAsString(snapshot);
        }
      } catch (_) {}
    });
  }
}
