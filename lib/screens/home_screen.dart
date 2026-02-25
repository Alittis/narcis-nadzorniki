import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/screens/form_screen.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/services/location_service.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _mapController = MapController();
  final _locationService = LocationService();
  LatLng _center = const LatLng(45.75, 14.39);
  LatLng? _userLocation;

  @override
  void initState() {
    super.initState();
    _loadUserLocation();
  }

  Future<void> _loadUserLocation() async {
    final location = await _locationService.getCurrentLocation();
    if (!mounted || location == null) {
      return;
    }
    setState(() {
      _userLocation = location;
      _center = location;
    });
  }

  Color _markerColor(Disturbance record) {
    final now = DateTime.now();
    final age = now.difference(record.observedAt).inDays;
    if (age <= 31) {
      return Colors.red;
    }
    if (age <= 365) {
      return Colors.orange;
    }
    return Colors.blue;
  }

  void _openForm(BuildContext context, AppState state) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FormScreen(
          initialLocation: _userLocation,
          initialObservers: state.lastObservers,
          mapCenter: _center,
        ),
      ),
    );
  }

  void _openSettingsSheet(AppState state) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nastavitve', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: state.offlineOverride,
                  onChanged: state.setOfflineOverride,
                  title: const Text('Offline način'),
                  subtitle: const Text('Shranjuj lokalno in čakati na sinhronizacijo.'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncIcon(AppState state) {
    if (state.pendingCount == 0) {
      return const Icon(Icons.sync);
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.sync),
        Positioned(
          right: -6,
          top: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(10),
            ),
            constraints: const BoxConstraints(minWidth: 16),
            child: Text(
              state.pendingCount.toString(),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final markers = <Marker>[
          ...state.records.map(
            (record) => Marker(
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
                  Icons.location_on,
                  color: _markerColor(record),
                  size: 38,
                ),
              ),
            ),
          ),
        ];
        if (_userLocation != null) {
          markers.add(
            Marker(
              point: _userLocation!,
              width: 40,
              height: 40,
              child: const Icon(
                Icons.my_location,
                color: Colors.blueGrey,
                size: 26,
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Motnje - teren'),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Chip(
                  label: Text(state.isOnline ? 'ONLINE' : 'OFFLINE'),
                  backgroundColor: state.isOnline ? Colors.green[100] : Colors.orange[100],
                  labelStyle: TextStyle(
                    color: state.isOnline ? Colors.green[900] : Colors.orange[900],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Sinhroniziraj',
                onPressed: state.isSyncing ? null : state.syncPending,
                icon: state.isSyncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _buildSyncIcon(state),
              ),
              IconButton(
                tooltip: 'Seznam',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecordListScreen(records: state.records),
                    ),
                  );
                },
                icon: const Icon(Icons.list_alt),
              ),
              IconButton(
                tooltip: 'Nastavitve',
                onPressed: () => _openSettingsSheet(state),
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
          body: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 13,
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
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'si.narcis.nadzorniki',
              ),
              MarkerLayer(markers: markers),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openForm(context, state),
            icon: const Icon(Icons.add),
            label: const Text('Nov zapis'),
          ),
        );
      },
    );
  }
}
