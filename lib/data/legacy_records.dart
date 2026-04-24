import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';

class LegacyRecordsLoader {
  static const _assetPath = 'assets/legacy/notranjski_park_2025.json';

  Future<List<LegacyDisturbance>> load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final records = payload['records'] as List<dynamic>;
    return records
        .map((entry) => LegacyDisturbance.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }
}
