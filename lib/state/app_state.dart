import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:narcis_nadzorniki/data/disturbance_types.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/data/walks_local_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';
import 'package:narcis_nadzorniki/services/photo_storage.dart';
import 'package:narcis_nadzorniki/services/walk_task_handler.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

class AppState extends ChangeNotifier {
  AppState({
    LocalStore? localStore,
    WalksLocalStore? walksStore,
    RemoteApi? remoteApi,
    Connectivity? connectivity,
    AuthService? authService,
    LegacyRecordsLoader? legacyLoader,
    PhotoStorage? photoStorage,
  })  : _localStore = localStore ?? LocalStore(),
        _walksStore = walksStore ?? WalksLocalStore(),
        _remoteApi = remoteApi ?? RemoteApi(),
        _connectivity = connectivity ?? Connectivity(),
        _authService = authService ?? AuthService(),
        _legacyLoader = legacyLoader ?? LegacyRecordsLoader(),
        _photoStorage = photoStorage ?? PhotoStorage();

  final LocalStore _localStore;
  final WalksLocalStore _walksStore;
  final RemoteApi _remoteApi;
  final Connectivity _connectivity;
  final AuthService _authService;
  final LegacyRecordsLoader _legacyLoader;
  final PhotoStorage _photoStorage;
  final _uuid = const Uuid();

  List<Disturbance> _records = [];
  List<LegacyDisturbance> _legacyRecords = [];
  // Legacy overlay disabled: its data now lives in TB_MOTNJE proper (per the
  // 2026-05-22 Notranjski backfill, commit 1430a5a) and would duplicate the
  // regular disturbance markers. Field + loader + detail screen kept for a
  // follow-up full removal.
  bool _showLegacy = false;
  bool _offlineOverride = false;
  bool _isSyncing = false;
  ConnectivityResult _connectivityResult = ConnectivityResult.none;
  StreamSubscription<dynamic>? _connectivitySub;
  List<String> _lastObservers = [];
  String? _currentUser;
  // Bearer session token: the primary sync credential. Minted by the server on
  // a successful ONLINE login (see AuthService), persisted in secure storage,
  // and restored on app start for a sticky session across cold starts. Sent as
  // X-Narcis-Auth: Bearer <token> on every CRUD call - the password is never
  // stored or re-sent. Cleared on logout and on a sync 401 (revoked/expired).
  String? _sessionToken;
  // Fallback credential: the plaintext password, held in memory ONLY for the
  // current session and ONLY when the server didn't mint a token (older ORDS
  // deploy). Never written to disk. If neither a token nor this is present
  // (e.g. an offline manual login) queued records don't sync until the next
  // online login.
  String? _sessionPassword;
  // True until init() has restored any persisted session and decided whether to
  // show Home or Login - lets main.dart show a splash instead of flashing the
  // login screen on every cold start (incl. OS-killed background resumes).
  bool _bootstrapping = true;

  // Set of motnja IDs the server reported on the most recent successful pull.
  // Used to drive the "out of sync" indicator: if the server has IDs we
  // don't, the icon shows a download badge so the user knows a pull will
  // recover them. Null until the first successful pull.
  Set<String>? _lastRemoteIds;

  // Walk-around (obhod) state. Completed walks live in `_walks`. The
  // in-progress walk's metadata + growing point buffer live in
  // `active_walk.json`; the source of truth is the file (written by the
  // WalkTaskHandler background isolate). `_activeWalk` and `_activePoints`
  // are an in-memory mirror updated via SendPort messages from the FGS
  // isolate, so the UI can render live without re-reading the file every
  // frame. On app resume from a Samsung Freecess freeze the mirror is
  // rebuilt from the file.
  List<Walk> _walks = [];
  Walk? _activeWalk;
  List<WalkPoint> _activePoints = const [];
  StreamSubscription<dynamic>? _walkServicePortSub;
  Set<String>? _lastRemoteWalkIds;

  /// TB-2: rows queued for deletion are hidden here, so the map, the lists and
  /// the counters all behave as though the delete already happened. Sync code
  /// works off `_records` directly and still sees them.
  List<Disturbance> get records =>
      List.unmodifiable(_records.where((r) => !r.pendingDelete));
  List<LegacyDisturbance> get legacyRecords => List.unmodifiable(_legacyRecords);
  bool get showLegacy => _showLegacy;
  bool get offlineOverride => _offlineOverride;
  bool get isSyncing => _isSyncing;
  List<String> get lastObservers => List.unmodifiable(_lastObservers);
  String? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get canSync =>
      _currentUser != null && (_sessionToken != null || _sessionPassword != null);
  bool get isBootstrapping => _bootstrapping;

  List<Walk> get walks => List.unmodifiable(_walks);
  Walk? get activeWalk => _activeWalk;
  List<WalkPoint> get activePoints => List.unmodifiable(_activePoints);
  bool get hasActiveWalk => _activeWalk != null;

  Future<AuthResult> login(String email, String password) async {
    final result = await _authService.login(
      email,
      password,
      online: isOnline,
    );
    if (result.success) {
      _currentUser = result.user;
      if (result.token != null) {
        // Online login minted a token: persistent, password not retained.
        _sessionToken = result.token;
        _sessionPassword = null;
      } else {
        // No token: either an offline login (can't sync) or an older backend
        // that doesn't mint - keep the password in memory for this session
        // only so sync still works via the Basic fallback.
        _sessionToken = null;
        _sessionPassword = result.wasOffline ? null : password;
      }
      notifyListeners();
      if (canSync) {
        unawaited(syncAll());
      }
    }
    return result;
  }

  Future<void> logout() async {
    // Drop any in-progress walk: the user is signing out, the next user
    // would not own that data. Stop the FGS service, clear the file, and
    // unbind the port.
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await _walkServicePortSub?.cancel();
    _walkServicePortSub = null;
    _activeWalk = null;
    _activePoints = const [];
    await _walksStore.clearActive();

    // Clear cached records + walks + recently-used observer suggestions so a
    // subsequent login as a DIFFERENT user on the same device doesn't see
    // the previous user's data. Persisted store files are overwritten so the
    // next AppState.init() loads empty. Photo files under
    // <docs>/disturbance_photos/ become orphans (no record points at them);
    // sweeping them is a follow-up.
    _records = [];
    _walks = [];
    _lastObservers = [];
    await _localStore.save(_records);
    await _walksStore.save(_walks);

    // Revoke the token server-side (best-effort, fire-and-forget so logout
    // stays snappy on a poor connection). revokeToken captures the token by
    // value, so clearing the local copy below doesn't disturb the in-flight
    // request; if it never lands, the token still expires on its own.
    final token = _sessionToken;
    if (token != null) {
      unawaited(_authService.revokeToken(token));
    }

    _currentUser = null;
    _sessionToken = null;
    _sessionPassword = null;
    _lastRemoteIds = null;
    _lastRemoteWalkIds = null;
    await _authService.clearCache();
    notifyListeners();
  }

  SyncCredentials? get _credentials {
    final email = _currentUser;
    if (email == null) return null;
    // Prefer the bearer token; fall back to the in-memory password (older
    // backend that didn't mint a token).
    final token = _sessionToken;
    if (token != null) return SyncCredentials.token(token);
    final password = _sessionPassword;
    if (password != null) {
      return SyncCredentials.basic(email: email, password: password);
    }
    return null;
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

  /// Same logic as [isAuthoredByCurrentUser] but for walks.
  bool isWalkAuthoredByCurrentUser(Walk walk) {
    if (walk.pendingSync) return true;
    final me = _currentUser?.toLowerCase();
    if (me == null) return false;
    final author = walk.createdBy?.toLowerCase();
    return author != null && author == me;
  }

  /// Records local-only that haven't been pushed yet (created offline or while
  /// the session password is missing) plus records whose photos still need to
  /// be uploaded, plus walks waiting to be pushed.
  int get pendingPushCount {
    final recs = _records
        .where((r) =>
            r.pendingSync || r.hasPendingPhotoUploads || r.pendingDelete)
        .length;
    final ws = _walks.where((w) => w.pendingSync).length;
    return recs + ws;
  }

  /// IDs the server reported but the local store hasn't pulled yet. Drives the
  /// "missing locally" badge on the sync icon. Empty until a successful pull.
  int get missingLocalCount {
    var missing = 0;
    final remoteRecs = _lastRemoteIds;
    if (remoteRecs != null) {
      final localIds = _records.map((r) => r.id).toSet();
      missing += remoteRecs.where((id) => !localIds.contains(id)).length;
    }
    final remoteWalks = _lastRemoteWalkIds;
    if (remoteWalks != null) {
      final localWalkIds = _walks.map((w) => w.id).toSet();
      missing += remoteWalks.where((id) => !localWalkIds.contains(id)).length;
    }
    return missing;
  }

  bool get isOutOfSync => pendingPushCount > 0 || missingLocalCount > 0;

  /// Total badge count for the sync icon. Sum of records-to-push and
  /// records-only-on-server.
  int get pendingCount => pendingPushCount + missingLocalCount;

  Future<void> init() async {
    try {
      _records = await _localStore.load();
      if (_records.isNotEmpty) {
        _lastObservers = _records.last.observers;
      }
      _walks = await _walksStore.load();
      // Resume any in-progress walk. The FGS background isolate is the
      // source of truth for points; if its FGS is still running (Samsung
      // Freecess froze main but kept the FGS alive), just rebuild the
      // mirror from disk and re-bind the port. If the FGS isn't running
      // but the file exists (e.g. app fully killed), restart the service
      // — the handler will pick up the buffer from the file.
      final restored = await _walksStore.loadActive();
      if (restored != null) {
        _activeWalk = restored;
        _activePoints = restored.points;
        final isRunning = await FlutterForegroundTask.isRunningService;
        if (isRunning) {
          await _bindWalkServicePort();
          debugPrint('[walk] resumed active walk ${restored.id} '
              '(FGS still running, ${restored.points.length} buffered points)');
        } else {
          await _startWalkService(restored);
          debugPrint('[walk] resumed active walk ${restored.id} '
              '(FGS restarted, ${restored.points.length} buffered points)');
        }
      }
      try {
        _legacyRecords = await _legacyLoader.load();
      } catch (_) {
        _legacyRecords = const [];
      }
      // Restore a persisted bearer-token session so the user stays logged in
      // across cold starts (including OS-killed background processes). The
      // token is validated lazily by the first sync call below; a revoked or
      // expired token 401s and clears the session (_handleSyncException).
      final session = await _authService.readStoredSession();
      if (session != null) {
        _currentUser = session.email;
        _sessionToken = session.token;
      }
    } finally {
      // Reveal Home or Login now — don't make the splash wait for the network
      // sync that follows.
      _bootstrapping = false;
      notifyListeners();
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
    // Stamp the author locally so the record reads as "mine" immediately,
    // before the next pull merges in the server-side `ustvarjen_od`. Without
    // this, freshly-created records render as outlined (teammate) markers
    // and hide the Avtor row from the moment the optimistic POST returns
    // until the next `_pullRemote` overwrites the local row.
    // If a walk is in progress, link the record to it server-side via
    // obhodId so the walk's detail view can show its captured disturbances.
    final newRecord = record.copyWith(
      photos: stablePhotos,
      pendingSync: true,
      createdBy: _currentUser,
      obhodId: record.obhodId ?? _activeWalk?.id,
    );
    _records = [..._records, newRecord];
    _lastObservers = newRecord.observers;
    await _localStore.save(_records);
    notifyListeners();
    debugPrint('[sync] addRecord ${newRecord.id} '
        'isOnline=$isOnline canSync=$canSync');
    // Optimistic push if we can. Failure leaves the record queued for
    // syncAll() to retry (connectivity tick, manual button, next login).
    // Skip the inline push if the record links to a walk that's not yet
    // on the server (active walk in progress, or a queued walk waiting
    // for its own push) — the FK on TB_MOTNJE.OBHOD_ID would 500 anyway.
    // syncAll() drains walks before records so the next sync resolves it,
    // and endWalk's post-push drain catches the active-walk case.
    if (isOnline && canSync) {
      if (_isWalkPending(newRecord.obhodId)) {
        debugPrint('[sync] addRecord ${newRecord.id} '
            'deferred: walk ${newRecord.obhodId} not yet on server');
      } else {
        final ok = await _sendAndMarkSynced(newRecord);
        if (ok) {
          await _drainPendingPhotos();
        }
      }
    }
  }

  /// True when [obhodId] points at a walk that hasn't reached the server yet
  /// — either the active walk (still being recorded) or a completed walk
  /// queued for push. Pushing a disturbance with such an obhodId would
  /// raise ORA-02291 (FK violation) and is therefore deferred.
  bool _isWalkPending(String? obhodId) {
    if (obhodId == null) return false;
    if (_activeWalk?.id == obhodId) return true;
    return _walks.any((w) => w.id == obhodId && w.pendingSync);
  }

  /// Triggers the OS permission dialog for POST_NOTIFICATIONS the first
  /// time a walk is started. No-op on Android < 13 (the OS reports
  /// granted by default). User can decline; we don't block the walk —
  /// but on Samsung devices the FGS will likely be killed shortly after
  /// the screen turns off without a visible notification, so the user
  /// will see a silently broken track. Logged for diagnosis.
  Future<void> _ensureNotificationPermission() async {
    final status = await Permission.notification.status;
    debugPrint('[walk] notification permission status: $status');
    if (status.isGranted || status.isPermanentlyDenied) return;
    final result = await Permission.notification.request();
    debugPrint('[walk] notification permission after request: $result');
  }

  /// Pops the OS-level "Allow X to be excluded from battery optimization?"
  /// dialog the first time a walk is started. Without this, Samsung One
  /// UI's "Freecess" mechanism can freeze the FGS isolate even with the
  /// notification visible — the symptom we hit during the field test
  /// (track is a straight line through the screen-off period).
  /// User can decline; subsequent walks won't re-prompt because the OS
  /// remembers the decision (status becomes permanentlyDenied).
  Future<void> _ensureBatteryOptimizationExempt() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    debugPrint('[walk] battery-opt status: $status');
    if (status.isGranted || status.isPermanentlyDenied) return;
    final result = await Permission.ignoreBatteryOptimizations.request();
    debugPrint('[walk] battery-opt after request: $result');
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

  /// TB-2: queues a delete instead of applying it locally and hoping the wire
  /// call lands.
  ///
  /// The old version removed the row and its photos immediately and only then
  /// tried the server, with no retry — so an offline delete looked like it
  /// worked and then **undid itself**: `_mergeRemoteIntoLocal` treats the server
  /// as authoritative, so the next pull found a row the server still had and no
  /// local copy, and re-created it (photos and all, re-downloaded). Marking it
  /// `pendingDelete` keeps the row addressable until the server confirms,
  /// survives a restart via the local store, and hides it from `records` in the
  /// meantime so the user sees the delete they asked for.
  /// Returns true when the server confirmed the delete and the row has been
  /// purged; false when it is still queued (offline, no session, or the call
  /// failed). The caller needs the difference to tell the user the truth —
  /// "deleted" and "will be deleted on the next sync" are not the same promise.
  Future<bool> deleteRecord(Disturbance record) async {
    _records = _records
        .map((item) =>
            item.id == record.id ? item.copyWith(pendingDelete: true) : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
    debugPrint('[sync] deleteRecord ${record.id} queued '
        'isOnline=$isOnline canSync=$canSync');
    if (isOnline && canSync) {
      await _drainPendingDeletes();
    }
    return !_records.any((r) => r.id == record.id);
  }

  /// Sends every queued delete and purges the ones the server confirms.
  ///
  /// A 404 counts as success — `RemoteApi.deleteRecord` accepts it — which is
  /// what makes this safe for a record whose create never landed, and for a
  /// retry after a response was lost. Anything else (network, 5xx) leaves the
  /// row queued for the next drain.
  Future<void> _drainPendingDeletes() async {
    final creds = _credentials;
    if (creds == null) return;
    // Snapshot: the loop mutates _records.
    final queued = _records.where((r) => r.pendingDelete).toList();
    if (queued.isEmpty) return;
    debugPrint('[sync] draining ${queued.length} pending delete(s)');
    for (final record in queued) {
      try {
        await _remoteApi.deleteRecord(record.id, creds);
      } on RemoteApiException catch (e) {
        debugPrint('[sync] delete ${record.id} FAILED, stays queued: $e');
        _handleSyncException(e);
        continue;
      }
      _records = _records.where((item) => item.id != record.id).toList();
      // TB-35: drop it from the last-pull snapshot too. `missingLocalCount`
      // counts ids the server reported that we don't hold locally, so leaving
      // a confirmed-deleted id in there makes the sync icon flip to the orange
      // cloud_download "Prenesi z strežnika (1 manjkajočih)" state until the
      // next pull happens to refresh the set. The delete had actually landed;
      // the indicator just claimed otherwise, which reads exactly like a
      // delete that failed to sync. The server no longer has this row, so our
      // record of what the server has must forget it at the same moment.
      _lastRemoteIds = _lastRemoteIds?.where((id) => id != record.id).toSet();
      await _photoStorage.deleteRecordDir(record.id);
      await _localStore.save(_records);
      notifyListeners();
      debugPrint('[sync] delete ${record.id} confirmed, purged locally');
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
      // 1. Walks first. The disturbance FK on TB_MOTNJE.OBHOD_ID requires
      //    the walk to exist server-side, so any record stamped with an
      //    obhodId of a not-yet-pushed walk would 500 if we sent it before
      //    its parent walk.
      final pendingWalks = _walks.where((w) => w.pendingSync).toList();
      debugPrint('[sync] pending walks to push: ${pendingWalks.length}');
      for (final walk in pendingWalks) {
        final ok = await _sendWalkAndMarkSynced(walk);
        debugPrint('[sync]   push walk ${walk.id} → $ok');
        if (!ok && !canSync) {
          debugPrint('[sync] aborting after auth-clear');
          return;
        }
      }
      // Skip records whose walk is still local-only (active walk in progress,
      // or queued walk that just failed to push above). Pushing them would
      // 500 with ORA-02291; endWalk's post-push drain or the next syncAll
      // (after the walk lands) will catch them up.
      // TB-2: a row queued for deletion is never pushed, even if its create
      // never landed. Posting it and then deleting it would be two pointless
      // round trips, and on a flaky link the POST could land while the DELETE
      // does not — leaving exactly the orphan the user asked us to remove.
      final pendingRecords = _records
          .where((r) =>
              r.pendingSync && !r.pendingDelete && !_isWalkPending(r.obhodId))
          .toList();
      final deferred = _records
          .where((r) =>
              r.pendingSync && !r.pendingDelete && _isWalkPending(r.obhodId))
          .length;
      debugPrint('[sync] pending records to push: ${pendingRecords.length} '
          '(deferred waiting on walk: $deferred)');
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
      // TB-2: deletes go out before the pull, so a confirmed delete is purged
      // locally rather than being merged straight back in from the server list
      // fetched moments earlier.
      await _drainPendingDeletes();
      // Pull remote list to surface any IDs the device doesn't have locally.
      await _pullRemoteWalks();
      await _prefetchAllWalkPoints();
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
    final remoteIds = remote.map((r) => r.id).toSet();
    // Seed with local records that are either (a) still claimed by the
    // server or (b) queued for push (pendingSync). This evicts non-pending
    // local records the server no longer reports — typically because the
    // caller's org changed (e.g. same device, different tester account).
    // Without this gate, the previous session's records render on the map
    // for the new user (cross-account bleed).
    final byId = <String, Disturbance>{
      for (final r in _records)
        if (r.pendingSync || r.pendingDelete || remoteIds.contains(r.id))
          r.id: r,
    };
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
      } else if (local.pendingDelete) {
        // TB-2: the user deleted this locally and the DELETE hasn't landed yet.
        // The server still reports the row, but overwriting the local copy
        // would clear pendingDelete and the delete would silently undo itself
        // — the exact bug the queue exists to prevent. Leave local alone; the
        // next drain removes it from both sides.
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

  // ---- Walks (obhodi) ------------------------------------------------------

  /// Begins a new walk. Generates the UUID up front so the same id is used
  /// locally and on the server (idempotent POST). The active-walk file is
  /// flushed immediately so a crash between this call and the first GPS
  /// tick can still be resumed (the points list is just empty).
  ///
  /// Caller is responsible for ensuring location permission is already
  /// granted (typically because the home screen has been running its own
  /// position stream since boot). We start our own subscription here so
  /// the buffer keeps growing even if the user navigates away from home.
  Future<Walk> startWalk() async {
    if (_activeWalk != null) {
      return _activeWalk!;
    }
    // Permission flow on Android: notification (so the FGS notification
    // renders), then battery-optimization exemption (so Samsung One UI's
    // Freecess doesn't freeze the FGS isolate while the screen is off).
    // Both pop OS-level dialogs the first time; subsequent walks are
    // silent. iOS handles its own background indicator + activity type.
    if (Platform.isAndroid) {
      await _ensureNotificationPermission();
      await _ensureBatteryOptimizationExempt();
    }
    final now = DateTime.now();
    final walk = Walk(
      id: _uuid.v4(),
      startedAt: now,
      endedAt: now,
      pendingSync: true,
      createdBy: _currentUser,
      points: const [],
    );
    _activeWalk = walk;
    _activePoints = const [];
    // Persist metadata BEFORE starting the service — the WalkTaskHandler
    // reads active_walk.json on its onStart to know what walk it's tracking.
    await _walksStore.saveActive(walk);
    await _startWalkService(walk);
    debugPrint('[walk] startWalk ${walk.id}');
    notifyListeners();
    return walk;
  }

  /// Ends the in-progress walk and queues it for push. [name] and [notes]
  /// are optional metadata captured at end time. Returns the persisted
  /// walk so the UI can show "saved with N points" feedback.
  ///
  /// If [discardIfEmpty] is true and no points were captured (the user
  /// tapped Start then Stop without moving), the walk is dropped instead
  /// of saved — saves us from a flood of empty walks on the server.
  Future<Walk?> endWalk({
    String? name,
    String? notes,
    bool discardIfEmpty = true,
  }) async {
    final active = _activeWalk;
    if (active == null) return null;

    // Stop the FGS first so the handler can't append after we read.
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await _walkServicePortSub?.cancel();
    _walkServicePortSub = null;

    // Source of truth is the file — the handler may have written extra
    // points between our last received SendPort message and stopService.
    final fromDisk = await _walksStore.loadActive();
    final mergedPoints = fromDisk?.points ?? _activePoints;

    if (discardIfEmpty && mergedPoints.isEmpty) {
      _activeWalk = null;
      _activePoints = const [];
      await _walksStore.clearActive();
      debugPrint('[walk] endWalk ${active.id}: no points, discarded');
      notifyListeners();
      return null;
    }

    final completed = active.copyWith(
      endedAt: DateTime.now(),
      name: name,
      notes: notes,
      points: mergedPoints,
      pendingSync: true,
    );
    _walks = [..._walks, completed];
    _activeWalk = null;
    _activePoints = const [];
    await _walksStore.save(_walks);
    await _walksStore.clearActive();
    notifyListeners();
    debugPrint('[walk] endWalk ${completed.id}: '
        '${completed.points.length} points, queued for push');
    if (isOnline && canSync) {
      final ok = await _sendWalkAndMarkSynced(completed);
      if (ok) {
        // Walk now exists server-side; any disturbance captured during it
        // was deferred (or 500'd with FK) waiting for this. Push them now,
        // then drain photos.
        final blocked = _records
            .where((r) => r.pendingSync && r.obhodId == completed.id)
            .toList();
        debugPrint('[sync] endWalk drain: '
            '${blocked.length} record(s) waiting on walk ${completed.id}');
        for (final rec in blocked) {
          await _sendAndMarkSynced(rec);
        }
        await _drainPendingPhotos();
      }
    }
    return completed;
  }

  /// Discards the in-progress walk without saving. Used when the user
  /// explicitly cancels (no field-data value).
  Future<void> cancelWalk() async {
    if (_activeWalk == null) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await _walkServicePortSub?.cancel();
    _walkServicePortSub = null;
    final id = _activeWalk!.id;
    _activeWalk = null;
    _activePoints = const [];
    await _walksStore.clearActive();
    notifyListeners();
    debugPrint('[walk] cancelWalk $id');
  }

  Future<void> updateWalk(Walk walk) async {
    _walks = _walks
        .map((w) => w.id == walk.id ? walk : w)
        .toList(growable: false);
    await _walksStore.save(_walks);
    notifyListeners();
    final creds = _credentials;
    if (isOnline && creds != null && !walk.pendingSync) {
      try {
        await _remoteApi.updateWalk(walk, creds);
      } on RemoteApiException catch (e) {
        _handleSyncException(e);
      }
    }
  }

  Future<void> deleteWalk(Walk walk) async {
    _walks = _walks.where((w) => w.id != walk.id).toList();
    await _walksStore.save(_walks);
    notifyListeners();
    final creds = _credentials;
    if (isOnline && creds != null && !walk.pendingSync) {
      try {
        await _remoteApi.deleteWalk(walk.id, creds);
        // TB-35: same snapshot problem as the record delete above — but only
        // on success. A walk removed locally whose server DELETE failed IS
        // genuinely missing locally, and the badge saying so is correct.
        _lastRemoteWalkIds =
            _lastRemoteWalkIds?.where((id) => id != walk.id).toSet();
        notifyListeners();
      } on RemoteApiException catch (e) {
        _handleSyncException(e);
      }
    }
  }

  /// Lazy-loads a walk's track points from the server and caches them on
  /// the walk row. No-op if points are already loaded or we have no creds.
  Future<List<WalkPoint>> ensureWalkPointsCached(String walkId) async {
    final walk = _walks.where((w) => w.id == walkId).firstOrNull;
    if (walk == null) return const [];
    if (walk.points.isNotEmpty) return walk.points;
    final creds = _credentials;
    if (creds == null || !isOnline) return const [];
    try {
      final pts = await _remoteApi.fetchWalkPoints(walkId, creds);
      _walks = _walks
          .map((w) => w.id == walkId ? w.copyWith(points: pts) : w)
          .toList(growable: false);
      await _walksStore.save(_walks);
      notifyListeners();
      return pts;
    } on RemoteApiException catch (e) {
      _handleSyncException(e);
      return const [];
    }
  }

  /// Starts the flutter_foreground_task service and binds the receivePort.
  /// The handler reads `active_walk.json` (just persisted by the caller)
  /// to learn which walk it's tracking.
  Future<void> _startWalkService(Walk walk) async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Snemanje obhoda',
      notificationText: 'Beležimo vašo pot na terenu.',
      callback: walkStartCallback,
    );
    await _bindWalkServicePort();
  }

  Future<void> _bindWalkServicePort() async {
    await _walkServicePortSub?.cancel();
    final port = FlutterForegroundTask.receivePort;
    if (port == null) {
      debugPrint('[walk] receivePort is null — cannot bind');
      return;
    }
    _walkServicePortSub = port.listen(_onWalkServiceMessage);
  }

  void _onWalkServiceMessage(dynamic data) {
    if (data is! Map) return;
    final type = data['type'];
    if (type == 'log') {
      debugPrint('[walk-svc] ${data['message']}');
      return;
    }
    if (type == 'tick') {
      final raw = data['point'];
      if (raw is! Map) return;
      final point = WalkPoint.fromJson(
        raw.cast<String, dynamic>(),
      );
      final active = _activeWalk;
      if (active == null) return;
      _activePoints = [..._activePoints, point];
      _activeWalk = active.copyWith(
        endedAt: point.timestamp,
        points: _activePoints,
      );
      notifyListeners();
    }
  }

  Future<bool> _sendWalkAndMarkSynced(Walk walk) async {
    final creds = _credentials;
    if (creds == null) {
      debugPrint('[sync] _sendWalkAndMarkSynced ${walk.id}: no creds');
      return false;
    }
    try {
      await _remoteApi.createWalk(walk, creds);
    } on RemoteApiException catch (e) {
      debugPrint('[sync] _sendWalkAndMarkSynced ${walk.id} FAILED: $e');
      _handleSyncException(e);
      return false;
    }
    _walks = _walks
        .map((w) => w.id == walk.id ? w.copyWith(pendingSync: false) : w)
        .toList(growable: false);
    await _walksStore.save(_walks);
    notifyListeners();
    return true;
  }

  Future<void> _pullRemoteWalks() async {
    final creds = _credentials;
    if (creds == null) return;
    try {
      final remote = await _remoteApi.fetchWalks(creds);
      _lastRemoteWalkIds = remote.map((r) => r.id).toSet();
      _walks = _mergeRemoteWalksIntoLocal(remote);
      await _walksStore.save(_walks);
      notifyListeners();
    } on RemoteApiException catch (e) {
      _handleSyncException(e);
    }
  }

  /// Eagerly download track points for every walk in the org that doesn't
  /// yet have geometry locally, so the home-map "Obhodi" layer renders all
  /// of them (own + teammate) without requiring a per-walk detail-screen
  /// open. Mirrors the disturbance pull, which is org-wide. Failures on one
  /// walk don't block the rest.
  Future<void> _prefetchAllWalkPoints() async {
    final creds = _credentials;
    if (creds == null) return;
    final targetIds = _walks
        .where((w) => w.points.isEmpty && !w.pendingSync)
        .map((w) => w.id)
        .toList();
    if (targetIds.isEmpty) return;
    final fetched = <String, List<WalkPoint>>{};
    for (final id in targetIds) {
      try {
        fetched[id] = await _remoteApi.fetchWalkPoints(id, creds);
      } on RemoteApiException catch (e) {
        _handleSyncException(e);
        if (_credentials == null) break;
      }
    }
    if (fetched.isEmpty) return;
    _walks = _walks
        .map((w) =>
            fetched.containsKey(w.id) ? w.copyWith(points: fetched[w.id]!) : w)
        .toList(growable: false);
    await _walksStore.save(_walks);
    notifyListeners();
  }

  List<Walk> _mergeRemoteWalksIntoLocal(List<RemoteWalk> remote) {
    final remoteIds = remote.map((w) => w.id).toSet();
    // Same cross-account-bleed eviction as _mergeRemoteIntoLocal — keep
    // pendingSync walks plus anything the server still claims.
    final byId = <String, Walk>{
      for (final w in _walks)
        if (w.pendingSync || remoteIds.contains(w.id)) w.id: w,
    };
    for (final r in remote) {
      final local = byId[r.id];
      if (local == null) {
        // Server-only walk: pull metadata in. Points are NOT included in
        // the list response; they'll lazy-fetch via ensureWalkPointsCached
        // when the user opens the walk's detail view.
        byId[r.id] = r.toLocal();
      } else if (local.pendingSync) {
        // Local has a queued walk with the same id (rare — would only
        // happen if a previous push partially completed). Trust local; the
        // next push is idempotent so the server state will catch up.
      } else {
        // Both sides have it. Server wins on metadata; preserve any
        // already-fetched points so we don't re-download.
        byId[r.id] = r.toLocal().copyWith(
              points: local.points,
              pointCount: r.pointCount,
              disturbanceCount: r.disturbanceCount,
            );
      }
    }
    return byId.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  // -------------------------------------------------------------------------

  void _handleSyncException(RemoteApiException e) {
    if (e.isUnauthorized) {
      // Token (or password) no longer accepted: drop the sync credential and
      // wipe the persisted token + offline cache so the next cold start lands
      // on the login screen. Queued records stay until the next online login.
      _sessionToken = null;
      _sessionPassword = null;
      unawaited(_authService.clearCache());
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _walkServicePortSub?.cancel();
    super.dispose();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
