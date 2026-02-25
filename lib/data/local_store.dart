import 'dart:convert';
import 'dart:io';

import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:path_provider/path_provider.dart';

class LocalStore {
  static const _fileName = 'motenj_store.json';

  Future<File> _file() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_fileName');
  }

  Future<List<Disturbance>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return [];
      }
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return [];
      }
      final decoded = jsonDecode(content) as List<dynamic>;
      return decoded
          .map((entry) => Disturbance.fromJson(entry as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Disturbance> items) async {
    final file = await _file();
    final data = items.map((item) => item.toJson()).toList();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }
}
