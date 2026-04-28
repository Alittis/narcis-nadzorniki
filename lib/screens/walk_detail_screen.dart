import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/walk.dart';
import 'package:narcis_nadzorniki/screens/detail_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:narcis_nadzorniki/widgets/basemap.dart';
import 'package:provider/provider.dart';

class WalkDetailScreen extends StatefulWidget {
  const WalkDetailScreen({super.key, required this.walkId});

  final String walkId;

  @override
  State<WalkDetailScreen> createState() => _WalkDetailScreenState();
}

class _WalkDetailScreenState extends State<WalkDetailScreen> {
  bool _fetched = false;

  @override
  void initState() {
    super.initState();
    // Lazy-fetch the walk's track points if they're not already cached on
    // the local row. Runs async; the build pulls fresh state from AppState
    // once the points arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePoints();
    });
  }

  Future<void> _ensurePoints() async {
    if (_fetched) return;
    _fetched = true;
    final state = context.read<AppState>();
    await state.ensureWalkPointsCached(widget.walkId);
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podrobnosti obhoda'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final walk = state.walks
              .where((w) => w.id == widget.walkId)
              .firstOrNull;
          if (walk == null) {
            return const Center(child: Text('Obhod ni najden.'));
          }
          final linked = state.records
              .where((r) => r.obhodId == walk.id)
              .toList()
            ..sort((a, b) => a.observedAt.compareTo(b.observedAt));

          return ListView(
            padding: EdgeInsets.fromLTRB(0, 0, 0, 16 + bottomInset),
            children: [
              _MapSection(walk: walk, linked: linked),
              const SizedBox(height: 12),
              _MetaSection(walk: walk, dateFormat: dateFormat),
              const SizedBox(height: 8),
              if (walk.notes?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    walk.notes!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              _LinkedRecordsSection(linked: linked, dateFormat: dateFormat),
            ],
          );
        },
      ),
    );
  }
}

class _MapSection extends StatelessWidget {
  const _MapSection({required this.walk, required this.linked});

  final Walk walk;
  final List<Disturbance> linked;

  @override
  Widget build(BuildContext context) {
    final pts = walk.points;
    // Center the map on the path's midpoint when we have points; fall back
    // to the walk's start coordinate when the points haven't arrived yet
    // (the user opened the screen offline, or fetch is still in flight).
    LatLng center;
    double zoom;
    if (pts.isNotEmpty) {
      center = pts[pts.length ~/ 2].location;
      zoom = 15;
    } else {
      center = const LatLng(46.15, 14.99);
      zoom = 8;
    }
    return SizedBox(
      height: 280,
      child: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: center,
              initialZoom: zoom,
              maxZoom: kMapMaxZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              ...basemapTileLayers(BasemapMode.osm),
              if (pts.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: pts.map((p) => p.location).toList(),
                      color: Colors.green.withValues(alpha: 0.85),
                      strokeWidth: 5,
                    ),
                  ],
                ),
              if (linked.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final r in linked)
                      Marker(
                        point: LatLng(r.latitude, r.longitude),
                        width: 36,
                        height: 36,
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 32,
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (pts.isEmpty)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text('Točke še niso bile prenesene…'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaSection extends StatelessWidget {
  const _MetaSection({required this.walk, required this.dateFormat});

  final Walk walk;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (walk.name?.isNotEmpty == true)
            Text(
              walk.name!,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          const SizedBox(height: 4),
          Text(
            '${dateFormat.format(walk.startedAt)} → '
            '${dateFormat.format(walk.endedAt)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${walk.duration.inMinutes} min • '
            '${walk.displayPointCount} točk',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (walk.pendingSync) ...[
            const SizedBox(height: 4),
            const Text(
              'V čakalni vrsti za pošiljanje',
              style: TextStyle(color: Colors.orange),
            ),
          ],
        ],
      ),
    );
  }
}

class _LinkedRecordsSection extends StatelessWidget {
  const _LinkedRecordsSection({
    required this.linked,
    required this.dateFormat,
  });

  final List<Disturbance> linked;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    if (linked.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Med obhodom ni bilo zabeleženih motenj.'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Motnje med obhodom (${linked.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final r in linked)
          ListTile(
            leading: const Icon(Icons.report_problem, color: Colors.red),
            title: Text(
              r.types.isEmpty
                  ? 'Brez tipa'
                  : r.types.map((t) => t.typeName).join(', '),
            ),
            subtitle: Text(dateFormat.format(r.observedAt)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailScreen(record: r),
                ),
              );
            },
          ),
      ],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
