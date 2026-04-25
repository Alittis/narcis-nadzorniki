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

  List<Disturbance> get records => List.unmodifiable(_records);
  List<LegacyDisturbance> get legacyRecords => List.unmodifiable(_legacyRecords);
  bool get showLegacy => _showLegacy;
  bool get offlineOverride => _offlineOverride;
  bool get isSyncing => _isSyncing;
  List<String> get lastObservers => List.unmodifiable(_lastObservers);
  String? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;

  Future<AuthResult> login(String email, String password) async {
    final result = await _authService.login(
      email,
      password,
      online: isOnline,
    );
    if (result.success) {
      _currentUser = result.user;
      notifyListeners();
    }
    return result;
  }

  Future<void> logout() async {
    _currentUser = null;
    // Wipe the offline credential cache too, so a logged-out device cannot
    // re-login offline with the previous user's password.
    await _authService.clearCache();
    notifyListeners();
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
    final newRecord = record.copyWith(pendingSync: !isOnline);
    _records = [..._records, newRecord];
    _lastObservers = newRecord.observers;
    await _localStore.save(_records);
    notifyListeners();
    if (isOnline) {
      await _sendAndMarkSynced(newRecord);
    }
  }

  Future<void> updateRecord(Disturbance record) async {
    _records = _records
        .map((item) => item.id == record.id ? record : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
    if (isOnline) {
      await _remoteApi.updateRecord(record);
    }
  }

  Future<void> deleteRecord(Disturbance record) async {
    _records = _records.where((item) => item.id != record.id).toList();
    await _localStore.save(_records);
    notifyListeners();
    if (isOnline) {
      await _remoteApi.deleteRecord(record.id);
    }
  }

  Future<void> syncPending() async {
    if (!isOnline || _isSyncing) {
      return;
    }
    _isSyncing = true;
    notifyListeners();
    final pending = _records.where((item) => item.pendingSync).toList();
    for (final record in pending) {
      await _sendAndMarkSynced(record);
    }
    _isSyncing = false;
    notifyListeners();
  }

  Future<void> _sendAndMarkSynced(Disturbance record) async {
    await _remoteApi.createRecord(record);
    _records = _records
        .map((item) => item.id == record.id
            ? item.copyWith(pendingSync: false)
            : item)
        .toList(growable: false);
    await _localStore.save(_records);
    notifyListeners();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}
