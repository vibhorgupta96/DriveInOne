import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import '../../../../domain/entities/media_item.dart';
import '../../../../domain/entities/resolved_media.dart';
import '../../../providers/auth_providers.dart';

class PhotoViewer extends ConsumerStatefulWidget {
  final MediaItemEntity mediaItem;

  const PhotoViewer({super.key, required this.mediaItem});

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  late Future<ResolvedMedia> _resolvedMedia;

  @override
  void initState() {
    super.initState();
    _resolvedMedia = _resolve();
  }

  @override
  void didUpdateWidget(covariant PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaItem.id != widget.mediaItem.id) {
      _resolvedMedia = _resolve();
    }
  }

  Future<ResolvedMedia> _resolve() =>
      ref.read(authRepositoryProvider).resolveMedia(widget.mediaItem);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ResolvedMedia>(
      future: _resolvedMedia,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
          );
        }

        final media = snapshot.data!;
        return PhotoView(
          imageProvider: NetworkImage(
            media.uri.toString(),
            headers: media.headers,
          ),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3,
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          loadingBuilder: (context, event) {
            return Center(
              child: CircularProgressIndicator(
                value: event == null
                    ? null
                    : event.cumulativeBytesLoaded /
                        (event.expectedTotalBytes ?? 1),
                color: Colors.white,
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Icon(
                Icons.broken_image,
                color: Colors.white54,
                size: 64,
              ),
            );
          },
        );
      },
    );
  }
}
