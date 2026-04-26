import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/data/legacy_records.dart';
import 'package:narcis_nadzorniki/data/local_store.dart';
import 'package:narcis_nadzorniki/data/remote_api.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/services/auth_service.dart';

class AppState extends ChangeNotifier {
  AppState({
    LocalStore? localStore,
    RemoteApi? remoteApi,
    Connectivity? connectivity,
    AuthService? authService,
    LegacyRecordsLoader? legacyLoader,
  })  : _localStore = localStore ?? LocalStore(),
        _remoteApi = remoteApi ?? RemoteApi(),
        _connectivity = connectivity ?? Connectivity(),
        _authService = authService ?? AuthService(),
        _legacyLoader = legacyLoader ?? LegacyRecordsLoader();

  final LocalStore _localStore;
  final RemoteApi _remoteApi;
  final Connectivity _connectivity;
  final AuthService _authService;
  final LegacyRecordsLoader _legacyLoader;

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
      // Only retain the plaintext password when the server actually accepted
      // it. An offline (cache-hit) login leaves _sessionPassword null - the
      // PBKDF2 cache is one-way and we cannot reconstruct what the server
      // would accept.
      _sessionPassword = result.wasOffline ? null : password;
      notifyListeners();
      if (canSync) {
        // Fresh online login - try to drain any queue that built up under a
        // prior offline session.
        unawaited(syncPending());
      }
    }
    return result;
  }

  Future<void> logout() async {
    _currentUser = null;
    _sessionPassword = null;
    // Wipe the offline credential cache too, so a logged-out device cannot
    // re-login offline with the previous user's password.
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

  int get pendingCount => _records.where((record) => record.pendingSync).length;

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
      _connectivityResult = _normalizeConnectivity(results);
      notifyListeners();
      if (isOnline) {
        syncPending();
      }
    });
    notifyListeners();
    if (isOnline) {
      await syncPending();
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
      syncPending();
    }
  }

  void setShowLegacy(bool value) {
    _showLegacy = value;
    notifyListeners();
  }

  Future<void> addRecord(Disturbance record) async {
    // pendingSync starts true if we have no path to sync now (offline OR
    // online but no session password). It clears once _sendAndMarkSynced
    // succeeds.
    final canPushNow = isOnline && canSync;
    final newRecord = record.copyWith(pendingSync: !canPushNow);
    _records = [..._records, newRecord];
    _lastObservers = newRecord.observers;
    await _localStore.save(_records);
    notifyListeners();
    if (canPushNow) {
      await _sendAndMarkSynced(newRecord);
    }
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

  Future<void> syncPending() async {
    if (!isOnline || _isSyncing || !canSync) {
      return;
    }
    _isSyncing = true;
    notifyListeners();
    try {
      final pending = _records.where((item) => item.pendingSync).toList();
      for (final record in pending) {
        final ok = await _sendAndMarkSynced(record);
        // 401 already cleared the session password and wiped the cache;
        // remaining queue cannot be drained until next online login.
        if (!ok && !canSync) break;
      }
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// Pushes one record to the server and clears its pendingSync flag on
  /// success. Returns true on success, false on failure (record stays
  /// pending). 401 also clears the session password so callers can stop
  /// retrying.
  Future<bool> _sendAndMarkSynced(Disturbance record) async {
    final creds = _credentials;
    if (creds == null) return false;
    try {
      await _remoteApi.createRecord(record, creds);
    } on RemoteApiException catch (e) {
      _handleSyncException(e);
      return false;
    }
    _records = _records
        .map((item) => item.id == record.id
            ? item.copyWith(pendingSync: false)
            : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
    return true;
  }

  void _handleSyncException(RemoteApiException e) {
    if (e.isUnauthorized) {
      // Server said our credentials are no longer valid (revoked, password
      // changed, etc.). Drop the session password so we stop retrying with
      // a known-bad value, and wipe the offline cache so a future offline
      // login can't keep accepting the now-rejected password either.
      _sessionPassword = null;
      unawaited(_authService.clearCache());
      notifyListeners();
    }
    // Network and 5xx errors: leave pendingSync true so the next
    // connectivity tick / login retries automatically.
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}
