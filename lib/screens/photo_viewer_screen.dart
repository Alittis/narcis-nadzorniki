import 'dart:io';

import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/models/disturbance_photo.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:provider/provider.dart';

class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.motnjaId,
    required this.initialIndex,
  });

  final String motnjaId;
  final int initialIndex;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _controller;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<DisturbancePhoto> _photosFor(AppState state) {
    for (final r in state.records) {
      if (r.id == widget.motnjaId) return r.photos;
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Consumer<AppState>(
          builder: (_, state, __) {
            final count = _photosFor(state).length;
            if (count == 0) return const Text('');
            return Text('${_currentIndex + 1} / $count');
          },
        ),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final photos = _photosFor(state);
          if (photos.isEmpty) {
            return const Center(
              child: Text(
                'Ni fotografij.',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }
          return PhotoViewGallery.builder(
            pageController: _controller,
            itemCount: photos.length,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            onPageChanged: (index) => setState(() => _currentIndex = index),
            loadingBuilder: (_, __) => const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
            builder: (context, index) {
              final photo = photos[index];
              final path = photo.localPath;
              if (path == null) {
                return PhotoViewGalleryPageOptions.customChild(
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_download,
                            color: Colors.white70, size: 48),
                        SizedBox(height: 8),
                        Text(
                          'Slika še ni prenesena.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  heroAttributes: PhotoViewHeroAttributes(tag: photo.id),
                );
              }
              return PhotoViewGalleryPageOptions(
                imageProvider: FileImage(File(path)),
                heroAttributes: PhotoViewHeroAttributes(tag: photo.id),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 4,
              );
            },
          );
        },
      ),
    );
  }
}
