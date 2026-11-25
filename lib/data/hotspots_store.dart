import 'dart:convert';
import 'dart:io';

import 'package:narcis_nadzorniki/models/hotspot.dart';
import 'package:path_provider/path_provider.dart';

/// TB-39 (narcis-vibed NV-622): the org's hot spots as the last successful
/// `GET hotspots` listed them, so the map and the location picker show them
/// offline, where most field work happens. Replaced whole on every successful
/// pull and emptied at logout: the list is org-scoped, and the next account on
/// the device may be another org's.
///
/// Absent or unreadable reads as empty; a failed write is swallowed, as the
/// next pull writes it again.
class HotspotsStore {
  HotspotsStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static const _fileName = 'hotspots.json';
  final Future<Directory> Function() _directory;

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  Future<List<Hotspot>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      return Hotspot.listFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<Hotspot> hotspots) async {
    try {
      await (await _file())
          .writeAsString(jsonEncode([for (final h in hotspots) h.toJson()]));
    } catch (_) {}
  }
}
