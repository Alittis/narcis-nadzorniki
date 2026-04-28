import 'dart:convert';
import 'dart:io';

import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent storage for walk-around (obhod) records on the phone.
///
/// Two separate files:
/// - `walks_store.json` — completed walks (server-confirmed or queued for
///   push). Points are stripped from this file once the walk has been
///   pushed; they live server-side and are lazy-fetched on detail-view.
/// - `active_walk.json` — the in-progress walk and its growing point
///   buffer. Saved on every tick so an app kill mid-walk doesn't lose
///   captured data. Deleted on `endWalk` (the row is moved into
///   `walks_store.json` with `pendingSync=true`).
class WalksLocalStore {
  static const _walksFile = 'walks_store.json';
  static const _activeFile = 'active_walk.json';

  Future<File> _file(String name) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$name');
  }

  Future<List<Walk>> load() async {
    try {
      final file = await _file(_walksFile);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      final decoded = jsonDecode(content) as List<dynamic>;
      return decoded
          .map((entry) => Walk.fromJson(entry as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Walk> items) async {
    final file = await _file(_walksFile);
    final data = items.map((item) => item.toJson()).toList();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Reads the in-progress walk if one is on disk. Returns null when no
  /// active walk file exists or it's malformed (don't fail the app on a
  /// corrupted snapshot — just start fresh).
  Future<Walk?> loadActive() async {
    try {
      final file = await _file(_activeFile);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      return Walk.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveActive(Walk walk) async {
    final file = await _file(_activeFile);
    await file.writeAsString(jsonEncode(walk.toJson()));
  }

  Future<void> clearActive() async {
    final file = await _file(_activeFile);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
