import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/disturbance_types.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';

class AppState extends ChangeNotifier {
  AppState({
    LocalStore? localStore,
    RemoteApi? remoteApi,
    Connectivity? connectivity,
    AuthService? authService,
    LegacyRecordsLoader? legacyLoader,
    PhotoStorage? photoStorage,
  })  : _localStore = localStore ?? LocalStore(),
        _remoteApi = remoteApi ?? RemoteApi(),
        _connectivity = connectivity ?? Connectivity(),
        _authService = authService ?? AuthService(),
        _legacyLoader = legacyLoader ?? LegacyRecordsLoader(),
        _photoStorage = photoStorage ?? PhotoStorage();

  final LocalStore _localStore;
  final RemoteApi _remoteApi;
  final Connectivity _connectivity;
  final AuthService _authService;
  final LegacyRecordsLoader _legacyLoader;
  final PhotoStorage _photoStorage;

  List<Disturbance> _records = [];
  List<LegacyDisturbance> _legacyRecords = [];
  bool _showLegacy = true;
  bool _offlineOverride = false;
  bool _isSyncing = false;
  ConnectivityResult _connectivityResult = ConnectivityResult.none;
  StreamSubscription<dynamic>? _connectivitySub;
  List<String> _lastObservers = [];
  String? _currentUser;
  // Plaintext password held in memory ONLY after a successful online login.
  // Required because the disturbance CRUD endpoints re-authenticate every
  // call via X-Narcis-Auth: Basic <base64(email:password)>. Cleared on
  // logout, on a 401 from sync, and never written to disk - the offline
  // cache stores a one-way PBKDF2 hash, not the plaintext.
  // Implication: if the user logged in offline (cache hit, no plaintext),
  // queued records do not sync until the next online login.
  String? _sessionPassword;

  // Set of motnja IDs the server reported on the most recent successful pull.
  // Used to drive the "out of sync" indicator: if the server has IDs we
  // don't, the icon shows a download badge so the user knows a pull will
  // recover them. Null until the first successful pull.
  Set<String>? _lastRemoteIds;

  List<Disturbance> get records => List.unmodifiable(_records);
  List<LegacyDisturbance> get legacyRecords => List.unmodifiable(_legacyRecords);
  bool get showLegacy => _showLegacy;
  bool get offlineOverride => _offlineOverride;
  bool get isSyncing => _isSyncing;
  List<String> get lastObservers => List.unmodifiable(_lastObservers);
  String? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get canSync => _currentUser != null && _sessionPassword != null;

  Future<AuthResult> login(String email, String password) async {
    final result = await _authService.login(
      email,
      password,
      online: isOnline,
    );
    if (result.success) {
      _currentUser = result.user;
      _sessionPassword = result.wasOffline ? null : password;
      notifyListeners();
      if (canSync) {
        unawaited(syncAll());
      }
    }
    return result;
  }

  Future<void> logout() async {
    _currentUser = null;
    _sessionPassword = null;
    _lastRemoteIds = null;
    await _authService.clearCache();
    notifyListeners();
  }

  SyncCredentials? get _credentials {
    final email = _currentUser;
    final password = _sessionPassword;
    if (email == null || password == null) return null;
    return SyncCredentials(email: email, password: password);
  }

  bool get isOnline => !_offlineOverride && _connectivityResult != ConnectivityResult.none;

  /// True if the record was authored by the currently logged-in user.
  /// Local-only (`pendingSync`) records are owned by the caller by definition
  /// — `createdBy` is null until the server stamps `ustvarjen_od` on the
  /// next pull. Email comparison is case-insensitive to match the server's
  /// `LOWER(TRIM(email))` lookup in `pkg_tb_auth.authenticate`.
  bool isAuthoredByCurrentUser(Disturbance record) {
    if (record.pendingSync) return true;
    final me = _currentUser?.toLowerCase();
    if (me == null) return false;
    final author = record.createdBy?.toLowerCase();
    return author != null && author == me;
  }

  /// Records local-only that haven't been pushed yet (created offline or while
  /// the session password is missing) plus records whose photos still need to
  /// be uploaded.
  int get pendingPushCount =>
      _records.where((r) => r.pendingSync || r.hasPendingPhotoUploads).length;

  /// IDs the server reported but the local store hasn't pulled yet. Drives the
  /// "missing locally" badge on the sync icon. Empty until a successful pull.
  int get missingLocalCount {
    final remote = _lastRemoteIds;
    if (remote == null) return 0;
    final localIds = _records.map((r) => r.id).toSet();
    return remote.where((id) => !localIds.contains(id)).length;
  }

  bool get isOutOfSync => pendingPushCount > 0 || missingLocalCount > 0;

  /// Total badge count for the sync icon. Sum of records-to-push and
  /// records-only-on-server.
  int get pendingCount => pendingPushCount + missingLocalCount;

  Future<void> init() async {
    _records = await _localStore.load();
    if (_records.isNotEmpty) {
      _lastObservers = _records.last.observers;
    }
    try {
      _legacyRecords = await _legacyLoader.load();
    } catch (_) {
      _legacyRecords = const [];
    }
    final result = await _connectivity.checkConnectivity();
    _connectivityResult = _normalizeConnectivity(result);
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      final previous = _connectivityResult;
      _connectivityResult = _normalizeConnectivity(results);
      debugPrint('[sync] connectivity raw=$results normalized=$_connectivityResult '
          '(was=$previous, isOnline=$isOnline)');
      notifyListeners();
      if (isOnline) {
        syncAll();
      }
    });
    notifyListeners();
    if (isOnline) {
      await syncAll();
    }
  }

  ConnectivityResult _normalizeConnectivity(dynamic value) {
    if (value is ConnectivityResult) {
      return value;
    }
    if (value is List<ConnectivityResult>) {
      return value.isEmpty ? ConnectivityResult.none : value.first;
    }
    return ConnectivityResult.none;
  }

  void setOfflineOverride(bool value) {
    _offlineOverride = value;
    notifyListeners();
    if (isOnline) {
      syncAll();
    }
  }

  void setShowLegacy(bool value) {
    _showLegacy = value;
    notifyListeners();
  }

  Future<void> addRecord(Disturbance record) async {
    // Photos picked in the form are stored under temp paths from image_picker.
    // Move them into stable storage tied to motnja_id so they survive restarts
    // and so the upload queue can find them even if the temp dir was cleaned.
    final stablePhotos = await _materializePhotos(record);
    // ALWAYS enqueue as pendingSync=true. _sendAndMarkSynced flips it to false
    // only on a confirmed 2xx from the server. Pre-marking it false here on
    // the optimistic assumption that an inline push will succeed used to
    // strand records permanently when the inline push failed (network blip,
    // server 5xx, captive portal): syncAll() filters on pendingSync=true and
    // would never retry them. The manual sync button would then do nothing
    // visible, even though canSync was true.
    final newRecord = record.copyWith(
      photos: stablePhotos,
      pendingSync: true,
    );
    _records = [..._records, newRecord];
    _lastObservers = newRecord.observers;
    await _localStore.save(_records);
    notifyListeners();
    debugPrint('[sync] addRecord ${newRecord.id} '
        'isOnline=$isOnline canSync=$canSync');
    // Optimistic push if we can. Failure leaves the record queued for
    // syncAll() to retry (connectivity tick, manual button, next login).
    if (isOnline && canSync) {
      final ok = await _sendAndMarkSynced(newRecord);
      if (ok) {
        await _drainPendingPhotos();
      }
    }
  }

  Future<List<DisturbancePhoto>> _materializePhotos(Disturbance record) async {
    final out = <DisturbancePhoto>[];
    for (final photo in record.photos) {
      final src = photo.localPath;
      if (src == null || photo.id == src) {
        // Already abstract (e.g. pulled from server) - leave it alone.
        out.add(photo);
        continue;
      }
      try {
        final stable = await _photoStorage.savePicked(
          motnjaId: record.id,
          photoId: photo.id,
          sourcePath: src,
          mimeType: photo.mimeType,
        );
        out.add(photo.copyWith(localPath: stable, pendingUpload: true));
      } catch (_) {
        out.add(photo);
      }
    }
    return out;
  }

  Future<void> updateRecord(Disturbance record) async {
    _records = _records
        .map((item) => item.id == record.id ? record : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
    final creds = _credentials;
    if (isOnline && creds != null) {
      try {
        await _remoteApi.updateRecord(record, creds);
      } on RemoteApiException catch (e) {
        _handleSyncException(e);
      }
    }
  }

  Future<void> deleteRecord(Disturbance record) async {
    _records = _records.where((item) => item.id != record.id).toList();
    await _localStore.save(_records);
    await _photoStorage.deleteRecordDir(record.id);
    notifyListeners();
    final creds = _credentials;
    if (isOnline && creds != null) {
      try {
        await _remoteApi.deleteRecord(record.id, creds);
      } on RemoteApiException catch (e) {
        _handleSyncException(e);
      }
    }
  }

  /// Pushes any pending records and photos, then pulls the server list and
  /// merges in any records that were missing locally. Single entry-point
  /// behind the sync icon.
  Future<void> syncAll() async {
    debugPrint('[sync] syncAll() entry isOnline=$isOnline '
        'canSync=$canSync isSyncing=$_isSyncing');
    if (!isOnline || _isSyncing || !canSync) {
      debugPrint('[sync] syncAll() early-return');
      return;
    }
    _isSyncing = true;
    notifyListeners();
    try {
      final pendingRecords = _records.where((r) => r.pendingSync).toList();
      debugPrint('[sync] pending records to push: ${pendingRecords.length}');
      for (final record in pendingRecords) {
        final ok = await _sendAndMarkSynced(record);
        debugPrint('[sync]   push ${record.id} → $ok');
        if (!ok && !canSync) {
          debugPrint('[sync] aborting after auth-clear');
          return;
        }
      }
      // After records are persisted server-side, drain pending photos. We do
      // this in a second pass so a record that just got created can have its
      // photos uploaded in the same sync cycle.
      await _drainPendingPhotos();
      // Pull remote list to surface any IDs the device doesn't have locally.
      await _pullRemote();
    } finally {
      _isSyncing = false;
      notifyListeners();
      debugPrint('[sync] syncAll() exit');
    }
  }

  /// Backwards-compatible alias: existing call sites (connectivity tick,
  /// login post-success) call `syncPending`. Now that pulls and photos are
  /// also part of "sync", route them through the unified path.
  Future<void> syncPending() => syncAll();

  Future<bool> _sendAndMarkSynced(Disturbance record) async {
    final creds = _credentials;
    if (creds == null) {
      debugPrint('[sync] _sendAndMarkSynced ${record.id}: no creds');
      return false;
    }
    try {
      await _remoteApi.createRecord(record, creds);
    } on RemoteApiException catch (e) {
      debugPrint('[sync] _sendAndMarkSynced ${record.id} FAILED: $e');
      _handleSyncException(e);
      return false;
    }
    _records = _records
        .map((item) =>
            item.id == record.id ? item.copyWith(pendingSync: false) : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
    return true;
  }

  Future<void> _drainPendingPhotos() async {
    final creds = _credentials;
    if (creds == null) return;
    // Snapshot the current list because uploads will mutate _records under us.
    final candidates = _records
        .where((r) => !r.pendingSync && r.hasPendingPhotoUploads)
        .toList();
    for (final record in candidates) {
      for (final photo in record.photos) {
        if (!photo.pendingUpload) continue;
        final path = photo.localPath;
        if (path == null) continue;
        try {
          final bytes = await File(path).readAsBytes();
          await _remoteApi.uploadPhoto(
            motnjaId: record.id,
            photoId: photo.id,
            bytes: bytes,
            mimeType: photo.mimeType,
            credentials: creds,
          );
          _markPhotoSynced(record.id, photo.id);
        } on RemoteApiException catch (e) {
          _handleSyncException(e);
          if (!canSync) return;
          // Network / 5xx: leave pendingUpload true for next tick.
        } catch (_) {
          // File read failed (deleted from disk?) - skip; the user will see
          // the photo missing in the detail view and can re-attach if they
          // care.
        }
      }
    }
    await _localStore.save(_records);
  }

  void _markPhotoSynced(String motnjaId, String photoId) {
    _records = _records.map((r) {
      if (r.id != motnjaId) return r;
      final updatedPhotos = r.photos
          .map((p) => p.id == photoId ? p.copyWith(pendingUpload: false) : p)
          .toList();
      return r.copyWith(photos: updatedPhotos);
    }).toList(growable: false);
    notifyListeners();
  }

  Future<void> _pullRemote() async {
    final creds = _credentials;
    if (creds == null) return;
    try {
      final remote = await _remoteApi.fetchRecords(creds);
      _lastRemoteIds = remote.map((r) => r.id).toSet();
      _records = _mergeRemoteIntoLocal(remote);
      await _localStore.save(_records);
      notifyListeners();
    } on RemoteApiException catch (e) {
      _handleSyncException(e);
      // Network/5xx: leave _lastRemoteIds alone so the divergence indicator
      // reflects whatever the most recent successful pull saw.
    }
  }

  List<Disturbance> _mergeRemoteIntoLocal(List<RemoteDisturbance> remote) {
    final byId = {for (final r in _records) r.id: r};
    for (final remoteRec in remote) {
      final local = byId[remoteRec.id];
      if (local == null) {
        // Server-only record (typical after a fresh install): pull it in
        // verbatim. Photos arrive without localPath; they'll lazy-fetch on
        // first detail-view open. Resolve type names against the local
        // codebook so the UI doesn't show raw codes.
        byId[remoteRec.id] = remoteRec.toLocal().copyWith(
              types: _resolveTypeNames(remoteRec.types),
            );
      } else if (local.pendingSync) {
        // Local has a queued create with the same ID. Trust local; the next
        // push will reconcile (POST is idempotent on motnja_id so the server
        // will accept it as 200/exists).
      } else {
        // Both sides know about this record. Server is authoritative for the
        // record fields, but preserve any localPaths we already cached for
        // photos so we don't re-download.
        final mergedPhotos = _mergePhotos(local.photos, remoteRec.photos);
        byId[remoteRec.id] = remoteRec.toLocal().copyWith(
              types: _resolveTypeNames(remoteRec.types),
              photos: mergedPhotos,
            );
      }
    }
    // Preserve local-only pending records (not yet on server).
    return byId.values.toList()
      ..sort((a, b) => b.observedAt.compareTo(a.observedAt));
  }

  List<DisturbancePhoto> _mergePhotos(
    List<DisturbancePhoto> local,
    List<DisturbancePhoto> remote,
  ) {
    final localById = {for (final p in local) p.id: p};
    return remote.map((r) {
      final cached = localById[r.id];
      if (cached?.localPath != null) {
        return r.copyWith(localPath: cached!.localPath);
      }
      return r;
    }).toList();
  }

  List<SelectedDisturbanceType> _resolveTypeNames(
    List<SelectedDisturbanceType> types,
  ) {
    return types.map((t) {
      final group = disturbanceTypeGroups
          .where((g) => g.code == t.groupCode)
          .firstOrNull;
      if (group == null) return t;
      final type = group.types
          .where((typ) => typ.code == t.typeCode)
          .firstOrNull;
      if (type == null) {
        return SelectedDisturbanceType(
          groupCode: t.groupCode,
          groupName: group.name,
          typeCode: t.typeCode,
          typeName: t.typeName,
        );
      }
      return SelectedDisturbanceType(
        groupCode: t.groupCode,
        groupName: group.name,
        typeCode: t.typeCode,
        typeName: type.name,
      );
    }).toList();
  }

  /// Lazy-loads a photo's BLOB from the server and caches it on disk. Returns
  /// the local path on success. No-op if the photo is already cached or if
  /// we have no sync credentials.
  Future<String?> ensurePhotoCached({
    required String motnjaId,
    required String photoId,
  }) async {
    final record = _records.where((r) => r.id == motnjaId).firstOrNull;
    if (record == null) return null;
    final photo = record.photos.where((p) => p.id == photoId).firstOrNull;
    if (photo == null) return null;
    if (photo.localPath != null) {
      // Confirm the file still exists; if it was wiped (cache cleared, etc.),
      // fall through and re-fetch.
      if (await File(photo.localPath!).exists()) {
        return photo.localPath;
      }
    }
    final creds = _credentials;
    if (creds == null || !isOnline) return null;
    try {
      final bytes = await _remoteApi.downloadPhoto(
        motnjaId: motnjaId,
        photoId: photoId,
        credentials: creds,
      );
      final path = await _photoStorage.saveBytes(
        motnjaId: motnjaId,
        photoId: photoId,
        mimeType: photo.mimeType,
        bytes: bytes,
      );
      _records = _records.map((r) {
        if (r.id != motnjaId) return r;
        final updated = r.photos
            .map((p) => p.id == photoId ? p.copyWith(localPath: path) : p)
            .toList();
        return r.copyWith(photos: updated);
      }).toList(growable: false);
      await _localStore.save(_records);
      notifyListeners();
      return path;
    } on RemoteApiException catch (e) {
      _handleSyncException(e);
      return null;
    }
  }

  void _handleSyncException(RemoteApiException e) {
    if (e.isUnauthorized) {
      _sessionPassword = null;
      unawaited(_authService.clearCache());
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
