import 'dart:convert';
import 'dart:io';

import 'package:narcis_nadzorniki/data/obmocja_store.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:path_provider/path_provider.dart';

/// The home map's layer choices, remembered across restarts (TB-40).
///
/// Layers only. The Motnje filter (author / period / status) is deliberately
/// not kept: a date window remembered from last week would silently hide every
/// new record, and nothing on the map says a filter is on.
class MapLayers {
  const MapLayers({
    required this.basemap,
    required this.showMotnje,
    required this.showObhodi,
    required this.showParcele,
    required this.zos,
  });

  /// What a first start shows.
  static const defaults = MapLayers(
    basemap: BasemapMode.osm,
    showMotnje: true,
    showObhodi: false,
    showParcele: false,
    zos: {ZosKind.n2k},
  );

  final BasemapMode basemap;
  final bool showMotnje;
  final bool showObhodi;
  final bool showParcele;

  /// Active "Območja s statusom" sublayers. Empty is a real choice (all off).
  final Set<ZosKind> zos;

  Map<String, dynamic> toJson() => {
        'basemap': basemap.name,
        'motnje': showMotnje,
        'obhodi': showObhodi,
        'parcele': showParcele,
        'obmocja': [for (final k in zosOrder) if (zos.contains(k)) k.name],
      };

  /// Tolerant: a missing or unknown value falls back to [defaults], so a file
  /// written by an older or newer build never breaks the map.
  static MapLayers fromJson(Map<String, dynamic> json) {
    bool flag(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    final rawZos = json['obmocja'];
    return MapLayers(
      basemap: BasemapMode.values.firstWhere(
        (m) => m.name == json['basemap'],
        orElse: () => defaults.basemap,
      ),
      showMotnje: flag('motnje', defaults.showMotnje),
      showObhodi: flag('obhodi', defaults.showObhodi),
      showParcele: flag('parcele', defaults.showParcele),
      zos: rawZos is List
          ? {
              for (final k in ZosKind.values)
                if (rawZos.contains(k.name)) k,
            }
          : defaults.zos,
    );
  }
}

/// Same shape as [MapViewStore]: one small JSON file, best-effort both ways.
class MapLayersStore {
  MapLayersStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static const _fileName = 'map_layers.json';
  final Future<Directory> Function() _directory;

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  Future<MapLayers?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      return MapLayers.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MapLayers layers) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(layers.toJson()));
    } catch (_) {
      // Best-effort; failure is non-fatal.
    }
  }
}
