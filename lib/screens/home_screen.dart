import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/data/map_view_store.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
import 'package:narcis_nadzorniki/models/legacy_disturbance.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/form_screen.dart';
import 'package:narcis_nadzorniki/screens/legacy_detail_screen.dart';
import 'package:narcis_nadzorniki/screens/place_search_screen.dart';
import 'package:narcis_nadzorniki/screens/profile_screen.dart';
import 'package:narcis_nadzorniki/screens/type_selection_screen.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/services/place_search_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

enum AppMode { motnje, obhodi, mode3, mode4 }

class _ModeDef {
  const _ModeDef({
    required this.icon,
    required this.color,
    required this.label,
    required this.enabled,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool enabled;
}

const Map<AppMode, _ModeDef> _modeDefs = {
  AppMode.motnje: _ModeDef(
    icon: Icons.report_problem,
    color: Colors.red,
    label: 'Motnje',
    enabled: true,
  ),
  AppMode.obhodi: _ModeDef(
    icon: Icons.directions_walk,
    color: Colors.green,
    label: 'Obhodi',
    enabled: true,
  ),
  AppMode.mode3: _ModeDef(
    icon: Icons.help_outline,
    color: Colors.grey,
    label: 'Način 3',
    enabled: false,
  ),
  AppMode.mode4: _ModeDef(
    icon: Icons.help_outline,
    color: Colors.grey,
    label: 'Način 4',
    enabled: false,
  ),
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _sloveniaCenter = LatLng(46.15, 14.99);
  static const _sloveniaZoom = 8.0;

  final _mapController = MapController();
  final _locationService = LocationService();
  final _imagePicker = ImagePicker();
  final _mapViewStore = MapViewStore();
  LatLng _center = _sloveniaCenter;
  double _initialZoom = _sloveniaZoom;
  bool _viewLoaded = false;
  LatLng? _userLocation;
  // Horizontal accuracy in metres. Drives the size of the translucent
  // halo around the user dot. Null until the first fix arrives.
  double? _userAccuracy;
  StreamSubscription<UserPosition>? _positionSub;
  BasemapMode _basemapMode = BasemapMode.osm;
  bool _locating = false;

  AppMode _activeMode = AppMode.motnje;
  bool _showMotnje = true;
  bool _showObhodi = false;

  bool _plusExpanded = false;
  // Location stamped at the moment the user declared intent (tapped "+"),
  // so a downstream camera or type-selection step can't drift the GPS.
  LatLng? _capturedLocation;

  @override
  void initState() {
    super.initState();
    _bootstrapView();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrapView() async {
    final cached = await _mapViewStore.load();
    if (!mounted) {
      return;
    }
    setState(() {
      if (cached != null) {
        _center = cached.center;
        _initialZoom = cached.zoom;
      }
      _viewLoaded = true;
    });
    // Order matters: the one-shot fix may pop the permission dialog. Only
    // start the continuous stream after that resolves so two concurrent
    // permission requests can't race.
    await _loadUserLocation();
    if (mounted) _startPositionStream();
  }

  /// Subscribes to the OS position stream so the dot + halo follow the user
  /// continuously while the app is foreground. Does NOT move the camera —
  /// that only happens on the explicit Locate button or the first cache-miss
  /// fix in `_loadUserLocation`. Saving to MapViewStore is also deliberately
  /// skipped here so we don't churn disk on every metre of movement.
  void _startPositionStream() {
    debugPrint('[gps] starting position stream');
    _positionSub = _locationService.watchPosition().listen(
      (pos) {
        debugPrint('[gps] tick lat=${pos.location.latitude.toStringAsFixed(5)} '
            'lon=${pos.location.longitude.toStringAsFixed(5)} '
            'acc=${pos.accuracy.toStringAsFixed(1)}m');
        if (!mounted) return;
        setState(() {
          _userLocation = pos.location;
          _userAccuracy = pos.accuracy;
        });
      },
      onError: (Object e, StackTrace s) {
        debugPrint('[gps] stream error: $e');
      },
      onDone: () {
        debugPrint('[gps] stream closed');
      },
    );
  }

  Future<void> _loadUserLocation() async {
    final position = await _locationService.getCurrentPosition();
    debugPrint('[gps] one-shot fix: '
        '${position == null ? "null (no permission / no service)" : "ok"}');
    if (!mounted || position == null) {
      return;
    }
    setState(() {
      _userLocation = position.location;
      _userAccuracy = position.accuracy;
      _center = position.location;
    });
    final currentZoom = _mapController.camera.zoom;
    final targetZoom = currentZoom < kUserZoom ? kUserZoom : currentZoom;
    _mapController.move(position.location, targetZoom);
    unawaited(
      _mapViewStore.save(
        MapViewport(center: position.location, zoom: targetZoom),
      ),
    );
  }

  Future<void> _recenterOnUser() async {
    setState(() => _locating = true);
    final position = await _locationService.getCurrentPosition();
    if (!mounted) {
      return;
    }
    setState(() {
      _locating = false;
      if (position != null) {
        _userLocation = position.location;
        _userAccuracy = position.accuracy;
        _center = position.location;
      }
    });
    if (position == null) {
      _showSnack('GPS lokacije ni mogoče pridobiti.');
      return;
    }
    final zoom = _mapController.camera.zoom;
    _mapController.move(position.location, zoom);
    unawaited(
      _mapViewStore.save(MapViewport(center: position.location, zoom: zoom)),
    );
  }

  Color _markerColor(Disturbance record) {
    final now = DateTime.now();
    final age = now.difference(record.observedAt).inDays;
    if (age <= 31) return Colors.red;
    if (age <= 365) return Colors.orange;
    return Colors.blue;
  }

  void _openLegacyDetail(LegacyDisturbance record) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LegacyDetailScreen(record: record)),
    );
  }

  void _openForm(
    AppState state, {
    LatLng? location,
    String? initialPhotoPath,
    List<SelectedDisturbanceType>? initialTypes,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FormScreen(
          initialLocation: location ?? _userLocation,
          initialObservers: state.lastObservers,
          mapCenter: _center,
          initialBasemap: _basemapMode,
          initialPhotoPath: initialPhotoPath,
          initialTypes: initialTypes,
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(builder: (_) => const PlaceSearchScreen()),
    );
    if (result == null || !mounted) return;
    setState(() => _center = result.location);
    _mapController.move(result.location, 14);
  }

  void _onModeTap(AppMode mode) {
    final def = _modeDefs[mode]!;
    if (!def.enabled) {
      _showSnack('${def.label}: kmalu.');
      return;
    }
    if (_activeMode != mode) {
      setState(() => _activeMode = mode);
    }
  }

  void _onPlusTap(AppState state) {
    final def = _modeDefs[_activeMode]!;
    if (!def.enabled) {
      _showSnack('${def.label}: kmalu.');
      return;
    }
    if (_activeMode == AppMode.obhodi) {
      // Walk mode: single-tap toggle. Start a walk if none is running,
      // otherwise open the end-walk sheet. No speed dial — disturbances
      // are still captured via the Motnje mode (their obhodId is stamped
      // automatically by AppState when a walk is active).
      if (state.hasActiveWalk) {
        _openEndWalkSheet(state);
      } else {
        unawaited(_handleStartWalk(state));
      }
      return;
    }
    if (_activeMode != AppMode.motnje) {
      _showSnack('${def.label}: kmalu.');
      return;
    }
    if (_plusExpanded) {
      _collapseSpeedDial();
      return;
    }
    setState(() {
      _plusExpanded = true;
      _capturedLocation = _userLocation;
    });
    // Kick off a fresh GPS read so it's ready by the time the user picks a
    // sub-action; falls back to the last known _userLocation otherwise.
    unawaited(_refreshCapturedLocation());
  }

  Future<void> _handleStartWalk(AppState state) async {
    if (!state.canSync && !state.isOnline) {
      // Walks created offline still queue locally (pendingSync=true) and
      // will push on the next online sync — same model as disturbances.
      // No early-return; let it through.
    }
    await state.startWalk();
    if (!mounted) return;
    _showSnack('Obhod se snema.');
  }

  Future<void> _openEndWalkSheet(AppState state) async {
    final result = await showModalBottomSheet<_EndWalkResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EndWalkSheet(pointCount: state.activePoints.length),
    );
    if (result == null || !mounted) return;
    if (result.discard) {
      await state.cancelWalk();
      if (!mounted) return;
      _showSnack('Obhod zavržen.');
      return;
    }
    final walk = await state.endWalk(
      name: result.name,
      notes: result.notes,
    );
    if (!mounted) return;
    if (walk == null) {
      _showSnack('Obhod brez točk — zavržen.');
    } else {
      _showSnack('Obhod shranjen (${walk.points.length} točk).');
    }
  }

  void _collapseSpeedDial() {
    if (!_plusExpanded) return;
    setState(() {
      _plusExpanded = false;
      _capturedLocation = null;
    });
  }

  Future<void> _refreshCapturedLocation() async {
    final fresh = await _locationService.getCurrentLocation();
    if (!mounted || !_plusExpanded || fresh == null) return;
    setState(() => _capturedLocation = fresh);
  }

  Future<void> _startPhotoFlow(AppState state) async {
    final location = _capturedLocation ?? _userLocation;
    setState(() {
      _plusExpanded = false;
      _capturedLocation = null;
    });
    XFile? picked;
    try {
      picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'camera_access_denied') {
        _showSnack('Kamera ni dovoljena.');
      } else {
        _showSnack('Napaka pri odpiranju kamere.');
      }
      return;
    }
    if (picked == null || !mounted) return;
    _openForm(state, location: location, initialPhotoPath: picked.path);
  }

  Future<void> _startCodebookFlow(AppState state) async {
    final location = _capturedLocation ?? _userLocation;
    setState(() {
      _plusExpanded = false;
      _capturedLocation = null;
    });
    final selections =
        await Navigator.of(context).push<List<SelectedDisturbanceType>>(
      MaterialPageRoute(
        builder: (_) => const TypeSelectionScreen(initialSelections: []),
      ),
    );
    if (!mounted) return;
    if (selections == null || selections.isEmpty) return;
    _openForm(state, location: location, initialTypes: selections);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_viewLoaded) {
      // Suppress the first frame until the cached viewport is restored,
      // otherwise cached-location opens flash the Slovenia bounding view.
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              Positioned.fill(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: _initialZoom,
                    maxZoom: kMapMaxZoom,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onTap: (tapPosition, point) {
                      _center = point;
                    },
                    onPositionChanged: (position, _) {
                      if (position.center != null) {
                        _center = position.center!;
                      }
                    },
                  ),
                  children: [
                    ...basemapTileLayers(_basemapMode),
                    if (_userLocation != null && _userAccuracy != null)
                      userAccuracyCircleLayer(
                        _userLocation!,
                        _userAccuracy!,
                      ),
                    if (_buildPolylines(state).isNotEmpty)
                      PolylineLayer(polylines: _buildPolylines(state)),
                    MarkerLayer(markers: _buildMarkers(state)),
                  ],
                ),
              ),
              _TopChrome(
                state: state,
                basemapMode: _basemapMode,
                showMotnje: _showMotnje,
                showObhodi: _showObhodi,
                showLegacy: state.showLegacy,
                onAvatarTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  );
                },
                onSearchTap: _openSearch,
                onSyncTap: state.isSyncing ? null : state.syncAll,
                onBasemapChanged: (m) => setState(() => _basemapMode = m),
                onMotnjeToggle: () =>
                    setState(() => _showMotnje = !_showMotnje),
                onObhodiToggle: () =>
                    setState(() => _showObhodi = !_showObhodi),
                onLegacyToggle: () => state.setShowLegacy(!state.showLegacy),
                onPlaceholderTap: (label) => _showSnack('$label: kmalu.'),
              ),
              if (_plusExpanded)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _collapseSpeedDial,
                  ),
                ),
              _BottomBar(
                activeMode: _activeMode,
                locating: _locating,
                onLocateTap: _locating ? null : _recenterOnUser,
                onModeTap: _onModeTap,
                onPlusTap: () => _onPlusTap(state),
                plusExpanded: _plusExpanded,
                walkActive: state.hasActiveWalk,
              ),
              if (_plusExpanded)
                _SpeedDialMiniFabs(
                  color: _modeDefs[_activeMode]!.color,
                  onPhotoTap: () => _startPhotoFlow(state),
                  onCodebookTap: () => _startCodebookFlow(state),
                ),
            ],
          ),
        );
      },
    );
  }

  List<Polyline> _buildPolylines(AppState state) {
    final out = <Polyline>[];
    // Historical walks under the Obhodi layer toggle. Walks whose points
    // haven't been fetched yet are skipped silently — open the walk in the
    // detail screen to fetch its geometry. Eager prefetch is deferred until
    // we have a sense of typical walk volume per user.
    if (_showObhodi) {
      for (final walk in state.walks) {
        if (walk.points.isEmpty) continue;
        out.add(
          Polyline(
            points: walk.points.map((p) => p.location).toList(),
            color: Colors.blueGrey.withValues(alpha: 0.55),
            strokeWidth: 3,
          ),
        );
      }
    }
    // Active walk (always rendered, regardless of Obhodi toggle, so the
    // user sees their path drawing while it records).
    if (state.hasActiveWalk && state.activePoints.length >= 2) {
      out.add(
        Polyline(
          points: state.activePoints.map((p) => p.location).toList(),
          color: Colors.green.withValues(alpha: 0.85),
          strokeWidth: 5,
        ),
      );
    }
    return out;
  }

  List<Marker> _buildMarkers(AppState state) {
    final markers = <Marker>[];
    if (state.showLegacy) {
      for (final record in state.legacyRecords) {
        markers.add(
          Marker(
            point: LatLng(record.latitude, record.longitude),
            width: 30,
            height: 30,
            child: GestureDetector(
              onTap: () => _openLegacyDetail(record),
              child: const Icon(
                Icons.circle,
                color: Colors.deepPurple,
                size: 14,
              ),
            ),
          ),
        );
      }
    }
    if (_showMotnje) {
      // Two passes so the user's own markers always sit on top of teammates'
      // when they overlap. flutter_map draws markers in list order.
      final mine = <Disturbance>[];
      final others = <Disturbance>[];
      for (final record in state.records) {
        (state.isAuthoredByCurrentUser(record) ? mine : others).add(record);
      }
      Marker buildMarker(Disturbance record, {required bool isMine}) {
        // Color encodes age (red ≤31d, orange ≤365d, blue older) for both
        // own and teammate records; shape encodes authorship (own = filled
        // pin, teammate = outlined pin). Keeps the age signal meaningful
        // for the full org set without color-aliasing.
        return Marker(
          point: LatLng(record.latitude, record.longitude),
          width: 44,
          height: 44,
          child: GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailScreen(record: record),
                ),
              );
            },
            child: Icon(
              isMine ? Icons.location_on : Icons.location_on_outlined,
              color: _markerColor(record),
              size: 38,
            ),
          ),
        );
      }
      for (final r in others) {
        markers.add(buildMarker(r, isMine: false));
      }
      for (final r in mine) {
        markers.add(buildMarker(r, isMine: true));
      }
    }
    if (_userLocation != null) {
      markers.add(userLocationMarker(_userLocation!));
    }
    return markers;
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.state,
    required this.basemapMode,
    required this.showMotnje,
    required this.showObhodi,
    required this.showLegacy,
    required this.onAvatarTap,
    required this.onSearchTap,
    required this.onSyncTap,
    required this.onBasemapChanged,
    required this.onMotnjeToggle,
    required this.onObhodiToggle,
    required this.onLegacyToggle,
    required this.onPlaceholderTap,
  });

  final AppState state;
  final BasemapMode basemapMode;
  final bool showMotnje;
  final bool showObhodi;
  final bool showLegacy;
  final VoidCallback onAvatarTap;
  final VoidCallback onSearchTap;
  final VoidCallback? onSyncTap;
  final ValueChanged<BasemapMode> onBasemapChanged;
  final VoidCallback onMotnjeToggle;
  final VoidCallback onObhodiToggle;
  final VoidCallback onLegacyToggle;
  final ValueChanged<String> onPlaceholderTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  _AvatarButton(
                    email: state.currentUser ?? '',
                    onTap: onAvatarTap,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _SearchPill(onTap: onSearchTap)),
                  const SizedBox(width: 8),
                  _SyncStatusButton(state: state, onTap: onSyncTap),
                  const SizedBox(width: 8),
                  _ChromeIconButton(
                    icon: basemapMode == BasemapMode.satellite
                        ? Icons.map_rounded
                        : Icons.satellite_alt_rounded,
                    tooltip: basemapMode == BasemapMode.satellite
                        ? 'Zemljevid'
                        : 'Satelitska slika',
                    enabled: state.isOnline,
                    onTap: () => onBasemapChanged(
                      basemapMode == BasemapMode.satellite
                          ? BasemapMode.osm
                          : BasemapMode.satellite,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _LayerChip(
                    icon: Icons.report_problem,
                    label: 'Motnje',
                    selected: showMotnje,
                    enabled: true,
                    onTap: onMotnjeToggle,
                  ),
                  _LayerChip(
                    icon: Icons.directions_walk,
                    label: 'Obhodi',
                    selected: showObhodi,
                    enabled: true,
                    onTap: onObhodiToggle,
                  ),
                  _LayerChip(
                    icon: Icons.shield_moon_outlined,
                    label: 'Območja',
                    selected: false,
                    enabled: false,
                    onTap: () => onPlaceholderTap('Območja'),
                  ),
                  _LayerChip(
                    icon: Icons.grid_on,
                    label: 'Parcele',
                    selected: false,
                    enabled: false,
                    onTap: () => onPlaceholderTap('Parcele'),
                  ),
                  _LayerChip(
                    icon: Icons.history,
                    label: 'Zgodovina',
                    selected: showLegacy,
                    enabled: true,
                    onTap: onLegacyToggle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.email, required this.onTap});

  final String email;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initial = email.isNotEmpty ? email[0].toUpperCase() : '?';
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Text(
              initial,
              style: TextStyle(
                color: scheme.onPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
      shape: const StadiumBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: const SizedBox(
          height: 40,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.search, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Išči kraj…',
                    style: TextStyle(color: Colors.black54),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncStatusButton extends StatelessWidget {
  const _SyncStatusButton({required this.state, required this.onTap});

  final AppState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isOnline = state.isOnline;
    final outOfSync = state.isOutOfSync;
    final badgeCount = state.pendingCount;

    final Color bg;
    final Color fg;
    final IconData iconData;
    final String tooltip;

    if (!isOnline) {
      bg = Colors.grey.shade300;
      fg = Colors.grey.shade800;
      iconData = Icons.cloud_off;
      tooltip = 'Brez povezave';
    } else if (outOfSync) {
      // Pull-only divergence (server has records we don't) gets a download
      // glyph; anything that needs to be sent up gets the warning glyph.
      // Either way the badge count tells the user how many records are
      // affected.
      bg = Colors.orange.shade100;
      fg = Colors.orange.shade900;
      if (state.pendingPushCount > 0) {
        iconData = Icons.cloud_upload;
        tooltip = 'Sinhroniziraj ($badgeCount neusklajenih)';
      } else {
        iconData = Icons.cloud_download;
        tooltip = 'Prenesi z strežnika ($badgeCount manjkajočih)';
      }
    } else {
      bg = Colors.green.shade100;
      fg = Colors.green.shade900;
      iconData = Icons.cloud_done;
      tooltip = 'Vse sinhronizirano';
    }

    Widget glyph;
    if (state.isSyncing) {
      glyph = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: fg),
      );
    } else {
      glyph = Icon(iconData, color: fg, size: 22);
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(child: glyph),
                if (badgeCount > 0)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      constraints: const BoxConstraints(minWidth: 18),
                      child: Text(
                        badgeCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Material(
      color: surface.withValues(alpha: enabled ? 0.95 : 0.6),
      shape: const CircleBorder(),
      elevation: enabled ? 2 : 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Tooltip(
            message: tooltip,
            child: Icon(
              icon,
              size: 22,
              color: enabled ? null : Colors.black38,
            ),
          ),
        ),
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  const _LayerChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = !enabled
        ? scheme.surface.withValues(alpha: 0.7)
        : selected
            ? scheme.primary
            : scheme.surface.withValues(alpha: 0.95);
    final fg = !enabled
        ? Colors.black38
        : selected
            ? scheme.onPrimary
            : Colors.black87;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: bg,
        shape: const StadiumBorder(),
        elevation: 1.5,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(
            height: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.activeMode,
    required this.locating,
    required this.onLocateTap,
    required this.onModeTap,
    required this.onPlusTap,
    required this.plusExpanded,
    required this.walkActive,
  });

  final AppMode activeMode;
  final bool locating;
  final VoidCallback? onLocateTap;
  final ValueChanged<AppMode> onModeTap;
  final VoidCallback onPlusTap;
  final bool plusExpanded;
  final bool walkActive;

  @override
  Widget build(BuildContext context) {
    final activeColor = _modeDefs[activeMode]!.color;
    // FAB icon depends on active mode + walk state. Motnje keeps the "+"
    // (rotated 45° to look like a close glyph when the speed dial is open).
    // Obhodi swaps to a walk icon when idle and a stop icon while a walk
    // is recording, so the affordance is unambiguous from across the room.
    final IconData fabIcon;
    final bool rotateOnExpand;
    if (activeMode == AppMode.obhodi) {
      fabIcon = walkActive ? Icons.stop : Icons.directions_walk;
      rotateOnExpand = false;
    } else {
      fabIcon = Icons.add;
      rotateOnExpand = true;
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              LocateButton(locating: locating, onTap: onLocateTap),
              _ModePill(activeMode: activeMode, onTap: onModeTap),
              _PlusButton(
                color: activeColor,
                icon: fabIcon,
                rotated: rotateOnExpand && plusExpanded,
                onTap: onPlusTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.activeMode, required this.onTap});

  final AppMode activeMode;
  final ValueChanged<AppMode> onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const StadiumBorder(),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: AppMode.values.map((mode) {
            final def = _modeDefs[mode]!;
            final isActive = mode == activeMode;
            final Color iconColor;
            if (!def.enabled) {
              iconColor = Colors.black26;
            } else if (isActive) {
              iconColor = Colors.white;
            } else {
              iconColor = Colors.black87;
            }
            return InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onTap(mode),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isActive ? def.color : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Tooltip(
                  message: def.label,
                  child: Icon(def.icon, color: iconColor, size: 22),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _SpeedDialMiniFabs extends StatelessWidget {
  const _SpeedDialMiniFabs({
    required this.color,
    required this.onPhotoTap,
    required this.onCodebookTap,
  });

  final Color color;
  final VoidCallback onPhotoTap;
  final VoidCallback onCodebookTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 0,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        // Bar inner vertical pad (12) + plus button (56) + gap (12) above the +.
        child: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _MiniSpeedDialButton(
                label: 'Foto',
                icon: Icons.photo_camera,
                color: color,
                onTap: onPhotoTap,
              ),
              const SizedBox(height: 12),
              _MiniSpeedDialButton(
                label: 'Šifrant',
                icon: Icons.list_alt,
                color: color,
                onTap: onCodebookTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlusButton extends StatelessWidget {
  const _PlusButton({
    required this.color,
    required this.icon,
    required this.rotated,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final bool rotated;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 6,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: AnimatedRotation(
              turns: rotated ? 0.125 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniSpeedDialButton extends StatelessWidget {
  const _MiniSpeedDialButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          shape: const StadiumBorder(),
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: color,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      ],
    );
  }
}

class _EndWalkResult {
  const _EndWalkResult({
    required this.discard,
    this.name,
    this.notes,
  });

  final bool discard;
  final String? name;
  final String? notes;
}

class _EndWalkSheet extends StatefulWidget {
  const _EndWalkSheet({required this.pointCount});

  final int pointCount;

  @override
  State<_EndWalkSheet> createState() => _EndWalkSheetState();
}

class _EndWalkSheetState extends State<_EndWalkSheet> {
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Končaj obhod',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.pointCount} zajetih točk.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Ime (neobvezno)',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                maxLength: 200,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Opombe (neobvezno)',
                  border: OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Zavrzi obhod?'),
                            content: const Text(
                              'Pot in zajete točke bodo izbrisane.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Prekliči'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Zavrzi'),
                              ),
                            ],
                          ),
                        );
                        if (confirm != true) return;
                        if (!context.mounted) return;
                        Navigator.of(context).pop(
                          const _EndWalkResult(discard: true),
                        );
                      },
                      child: const Text('Zavrzi'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final name = _nameController.text.trim();
                        final notes = _notesController.text.trim();
                        Navigator.of(context).pop(
                          _EndWalkResult(
                            discard: false,
                            name: name.isEmpty ? null : name,
                            notes: notes.isEmpty ? null : notes,
                          ),
                        );
                      },
                      child: const Text('Shrani'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
