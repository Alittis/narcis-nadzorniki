/// Photo attached to a [Disturbance]. Lives in three possible states:
///   - just attached on this device:    pendingUpload=true, localPath=path
///   - synced (server has it, we cached it locally): pendingUpload=false,
///                                                   localPath=path
///   - pulled from server but not yet downloaded: pendingUpload=false,
///                                                localPath=null
///
/// [id] is a client-generated UUID and matches the server's `FOTO_ID`. It is
/// stable across the upload round-trip so the upload endpoint can treat a
/// repeated POST as a no-op.
class DisturbancePhoto {
  const DisturbancePhoto({
    required this.id,
    required this.mimeType,
    required this.localPath,
    required this.pendingUpload,
  });

  final String id;
  final String mimeType;
  final String? localPath;
  final bool pendingUpload;

  bool get isCachedLocally => localPath != null;

  DisturbancePhoto copyWith({
    String? mimeType,
    String? localPath,
    bool? pendingUpload,
    bool clearLocalPath = false,
  }) {
    return DisturbancePhoto(
      id: id,
      mimeType: mimeType ?? this.mimeType,
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      pendingUpload: pendingUpload ?? this.pendingUpload,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mimeType': mimeType,
        'localPath': localPath,
        'pendingUpload': pendingUpload,
      };

  factory DisturbancePhoto.fromJson(Map<String, dynamic> json) {
    return DisturbancePhoto(
      id: json['id'] as String,
      mimeType: (json['mimeType'] as String?) ?? 'image/jpeg',
      localPath: json['localPath'] as String?,
      pendingUpload: (json['pendingUpload'] as bool?) ?? false,
    );
  }
}
