import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import '../../../../domain/entities/media_item.dart';

class PhotoViewer extends StatelessWidget {
  final MediaItemEntity mediaItem;

  const PhotoViewer({super.key, required this.mediaItem});

  @override
  Widget build(BuildContext context) {
    final url = mediaItem.fullSizeUrl ?? mediaItem.thumbnailUrl;

    if (url == null || url.isEmpty) {
      return const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
      );
    }

    return PhotoView(
      imageProvider: NetworkImage(url),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 3,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      loadingBuilder: (context, event) {
        return Center(
          child: CircularProgressIndicator(
            value: event == null
                ? null
                : event.cumulativeBytesLoaded / (event.expectedTotalBytes ?? 1),
            color: Colors.white,
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return const Center(
          child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
        );
      },
    );
  }
}
