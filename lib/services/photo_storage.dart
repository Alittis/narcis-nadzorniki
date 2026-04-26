import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Manages on-device photo files for disturbances.
///
/// Layout: `<app docs>/disturbance_photos/<motnja_id>/<foto_id>.<ext>`.
///
/// We don't reuse image_picker's temp path because those are not stable across
/// app restarts. The form copies each picked photo through this service so
/// the path saved to the local store survives. Photos pulled lazily from
/// the server land in the same layout so the rest of the app doesn't have
/// to care whether a photo originated locally or remotely.
class PhotoStorage {
  PhotoStorage({Directory Function()? rootResolver}) : _rootResolver = rootResolver;

  final Directory Function()? _rootResolver;

  Future<Directory> _root() async {
    if (_rootResolver != null) return _rootResolver();
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/disturbance_photos');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> _recordDir(String motnjaId) async {
    final root = await _root();
    final dir = Directory('${root.path}/$motnjaId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String extensionForMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'image/heic':
        return 'heic';
      case 'image/jpeg':
      default:
        return 'jpg';
    }
  }

  /// Copies a freshly-picked photo into stable storage and returns the path.
  Future<String> savePicked({
    required String motnjaId,
    required String photoId,
    required String sourcePath,
    required String mimeType,
  }) async {
    final dir = await _recordDir(motnjaId);
    final ext = extensionForMime(mimeType);
    final dest = File('${dir.path}/$photoId.$ext');
    await File(sourcePath).copy(dest.path);
    return dest.path;
  }

  /// Writes raw bytes (e.g. from a server download) to the canonical path.
  Future<String> saveBytes({
    required String motnjaId,
    required String photoId,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final dir = await _recordDir(motnjaId);
    final ext = extensionForMime(mimeType);
    final dest = File('${dir.path}/$photoId.$ext');
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }

  /// Removes the on-disk file for a photo if it exists. Best-effort.
  Future<void> deletePhotoFile(String? localPath) async {
    if (localPath == null) return;
    try {
      final file = File(localPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Cache cleanup failures aren't actionable; swallow them.
    }
  }

  /// Removes the entire per-record directory (used on disturbance delete).
  Future<void> deleteRecordDir(String motnjaId) async {
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$motnjaId');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Cache cleanup failures aren't actionable; swallow them.
    }
  }
}
