import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/data/disturbance_group_colors.dart';
import 'package:narcis_nadzorniki/models/disturbance.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/models/disturbance_type.dart';
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
  final _photoPageController = PageController();
  int _photoIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePhotos();
    });
  }

  @override
  void dispose() {
    _photoPageController.dispose();
    super.dispose();
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

  Disturbance _liveRecord(AppState state) {
    return state.records
            .where((r) => r.id == widget.record.id)
            .firstOrNull ??
        widget.record;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Podrobnosti zapisa'),
        actions: [
          Consumer<AppState>(
            builder: (context, state, _) {
              final live = _liveRecord(state);
              return _SyncBadge(record: live);
            },
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final live = _liveRecord(state);
          final author = live.createdBy;
          final showAuthor = author != null &&
              author.isNotEmpty &&
              !state.isAuthoredByCurrentUser(live);

          return ListView(
            padding: EdgeInsets.only(bottom: 16 + bottomInset),
            children: [
              _PhotoHero(
                photos: live.photos,
                motnjaId: live.id,
                pageController: _photoPageController,
                currentIndex: _photoIndex,
                onPageChanged: (i) => setState(() => _photoIndex = i),
              ),
              Transform.translate(
                offset: const Offset(0, -22),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _TypesCard(
                    types: live.types,
                    proposedType: live.proposedType,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Description(text: live.description),
                    const SizedBox(height: 14),
                    _MetaStrip(
                      observedAt: live.observedAt,
                      latitude: live.latitude,
                      longitude: live.longitude,
                      accuracy: live.locationAccuracy,
                      author: showAuthor ? author : null,
                    ),
                    const SizedBox(height: 10),
                    _FooterRow(
                      actionTaken: live.actionTaken,
                      legalBasis: live.legalBasis,
                      caseStatus: live.caseStatus,
                      observers: live.observers,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PhotoHero extends StatelessWidget {
  const _PhotoHero({
    required this.photos,
    required this.motnjaId,
    required this.pageController,
    required this.currentIndex,
    required this.onPageChanged,
  });

  final List<DisturbancePhoto> photos;
  final String motnjaId;
  final PageController pageController;
  final int currentIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.36;

    if (photos.isEmpty) {
      return Container(
        height: 120,
        color: colors.surfaceContainerLow,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                color: colors.onSurfaceVariant, size: 18),
            const SizedBox(width: 8),
            Text(
              'Ni fotografij',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            controller: pageController,
            itemCount: photos.length,
            onPageChanged: onPageChanged,
            itemBuilder: (context, i) {
              final photo = photos[i];
              return GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PhotoViewerScreen(
                        motnjaId: motnjaId,
                        initialIndex: i,
                      ),
                    ),
                  );
                },
                child: _PhotoSlide(photo: photo),
              );
            },
          ),
          if (photos.length > 1)
            Positioned(
              bottom: 32,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${currentIndex + 1} / ${photos.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhotoSlide extends StatelessWidget {
  const _PhotoSlide({required this.photo});

  final DisturbancePhoto photo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = photo.localPath;
    if (path == null) {
      return Container(
        color: colors.surfaceContainerLow,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_download_outlined,
                  size: 36, color: colors.onSurfaceVariant),
              const SizedBox(height: 6),
              Text(
                'Prenos fotografije ...',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return Hero(
      tag: photo.id,
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }
}

class _TypesCard extends StatelessWidget {
  const _TypesCard({required this.types, required this.proposedType});

  final List<SelectedDisturbanceType> types;
  final String? proposedType;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasProposed =
        proposedType != null && proposedType!.trim().isNotEmpty;

    return Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: types.isEmpty && !hasProposed
            ? Text(
                'Brez izbranih tipov',
                style: TextStyle(color: colors.onSurfaceVariant),
              )
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final type in types) _TypeChip(type: type),
                  if (hasProposed) _ProposedChip(text: proposedType!.trim()),
                ],
              ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.type});

  final SelectedDisturbanceType type;

  @override
  Widget build(BuildContext context) {
    final hue = disturbanceGroupColor(type.groupCode);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: disturbanceGroupTint(type.groupCode),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: disturbanceGroupBorder(type.groupCode),
          width: 1,
        ),
      ),
      child: Text(
        type.display,
        style: TextStyle(
          fontSize: 12,
          color: hue,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProposedChip extends StatelessWidget {
  const _ProposedChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.outline.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lightbulb_outline,
              size: 12, color: colors.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Description extends StatelessWidget {
  const _Description({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (text.trim().isEmpty) {
      return Text(
        'Brez opisa.',
        style: TextStyle(
          color: colors.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.35),
    );
  }
}

class _MetaStrip extends StatelessWidget {
  const _MetaStrip({
    required this.observedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.author,
  });

  final DateTime observedAt;
  final double latitude;
  final double longitude;
  final String accuracy;
  final String? author;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Pill(
          icon: Icons.calendar_today,
          text: dateFmt.format(observedAt),
          tabular: true,
        ),
        _Pill(
          icon: Icons.location_on_outlined,
          text:
              '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}',
          tabular: true,
        ),
        _Pill(icon: Icons.gps_fixed, text: accuracy),
        if (author != null) _Pill(icon: Icons.person_outline, text: author!),
      ],
    );
  }
}

class _FooterRow extends StatelessWidget {
  const _FooterRow({
    required this.actionTaken,
    required this.legalBasis,
    required this.caseStatus,
    required this.observers,
  });

  final String actionTaken;
  final String? legalBasis;
  final String caseStatus;
  final List<String> observers;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Pill(icon: Icons.gavel_rounded, text: actionTaken),
        if (legalBasis != null && legalBasis!.isNotEmpty)
          _Pill(icon: Icons.menu_book_outlined, text: legalBasis!),
        _Pill(icon: Icons.flag_outlined, text: caseStatus),
        if (observers.isNotEmpty)
          _Pill(icon: Icons.group_outlined, text: observers.join(', ')),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    this.tabular = false,
  });

  final IconData icon;
  final String text;
  final bool tabular;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurface,
              fontWeight: FontWeight.w500,
              fontFeatures:
                  tabular ? const [FontFeature.tabularFigures()] : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.record});

  final Disturbance record;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final IconData icon;
    final Color color;
    final String tooltip;
    if (record.pendingSync) {
      icon = Icons.cloud_upload_outlined;
      color = colors.tertiary;
      tooltip = 'V čakanju na sinhronizacijo';
    } else if (record.hasPendingPhotoUploads) {
      icon = Icons.cloud_sync_outlined;
      color = colors.tertiary;
      tooltip = 'Fotografije v čakanju';
    } else {
      icon = Icons.cloud_done_outlined;
      color = colors.primary;
      tooltip = 'Sinhronizirano';
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: tooltip,
        child: Icon(icon, color: color),
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
