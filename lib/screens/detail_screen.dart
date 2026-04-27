import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/screens/photo_viewer_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.record,
  });

  final Disturbance record;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  @override
  void initState() {
    super.initState();
    // Lazy-fetch any photos that exist on the server but haven't been
    // downloaded yet. Runs async; the build pulls fresh state from AppState
    // when files arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePhotos();
    });
  }

  Future<void> _ensurePhotos() async {
    final state = context.read<AppState>();
    for (final photo in widget.record.photos) {
      if (photo.localPath != null) continue;
      if (photo.pendingUpload) continue;
      await state.ensurePhotoCached(
        motnjaId: widget.record.id,
        photoId: photo.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podrobnosti zapisa'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          // Re-resolve the record from state so photo localPaths populated
          // by ensurePhotoCached show up without rebuilding from props.
          final live = state.records
                  .where((r) => r.id == widget.record.id)
                  .firstOrNull ??
              widget.record;
          final author = live.createdBy;
          final showAuthor = author != null &&
              author.isNotEmpty &&
              !state.isAuthoredByCurrentUser(live);
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
            children: [
              _InfoRow(
                label: 'Status sinhronizacije',
                value: live.pendingSync
                    ? 'V čakanju'
                    : (live.hasPendingPhotoUploads
                        ? 'Fotografije v čakanju'
                        : 'Sinhronizirano'),
              ),
              if (showAuthor) _InfoRow(label: 'Avtor', value: author),
              _InfoRow(label: 'Datum/čas', value: dateFormat.format(live.observedAt)),
              _InfoRow(
                label: 'Lokacija',
                value: '${live.latitude.toStringAsFixed(5)}, ${live.longitude.toStringAsFixed(5)}',
              ),
              _InfoRow(label: 'Natančnost', value: live.locationAccuracy),
              _InfoRow(label: 'Ukrepanje', value: live.actionTaken),
              _InfoRow(
                label: 'Opazovalci',
                value: live.observers.isEmpty ? '—' : live.observers.join(', '),
              ),
              const SizedBox(height: 12),
              Text('Tipi motenj', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...live.types.map((type) => Text('• ${type.display}')),
              if (live.proposedType != null && live.proposedType!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Predlagan tip: ${live.proposedType}'),
              ],
              const SizedBox(height: 16),
              Text('Opis', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(live.description.isEmpty ? '—' : live.description),
              const SizedBox(height: 16),
              Text('Fotografije', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (live.photos.isEmpty)
                const Text('Ni pripetih fotografij.')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < live.photos.length; i++)
                      _PhotoTile(
                        photo: live.photos[i],
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PhotoViewerScreen(
                                motnjaId: live.id,
                                initialIndex: i,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.photo, required this.onTap});

  final DisturbancePhoto photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = photo.localPath;
    if (path == null) {
      // No local file yet — either we haven't fetched it or the fetch
      // failed (offline / 401). Render a placeholder so the user knows the
      // photo exists on the server.
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            color: Colors.black12,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Icon(Icons.cloud_download, color: Colors.black45),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Hero(
              tag: photo.id,
              child: Image.file(
                File(path),
                width: 90,
                height: 90,
                fit: BoxFit.cover,
              ),
            ),
          ),
          if (photo.pendingUpload)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_upload, size: 14, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
