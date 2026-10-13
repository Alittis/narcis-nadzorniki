import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The dataset generation the server's lists were last served under
/// (`X-Beleznica-Generation`, narcis-vibed NV-259 D6; TB-46). The server mints
/// a new one when its data set is replaced — the cutover from Oracle, or a
/// restore from a backup — and [AppState] then re-sends this user's own
/// records instead of evicting the ones the server lost.
///
/// One value in a plain file beside the record stores. Absent or unreadable
/// reads as null, which the next pull treats as a new generation: that re-sends
/// own records the server does not list, and the server's skip-if-exists POST
/// makes that safe.
class DatasetGenerationStore {
  DatasetGenerationStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static const _fileName = 'dataset_generation.txt';
  final Future<Directory> Function() _directory;

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  Future<String?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// A failed write is swallowed. The value stays unsaved, so every later pull
  /// counts as a new generation and re-sends own records the server does not
  /// list, including ones deleted on the web since. The record stores sit in
  /// the same directory, so they would fail with it.
  Future<void> save(String generation) async {
    try {
      await (await _file()).writeAsString(generation);
    } catch (_) {}
  }
}
