import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/enums/media_type.dart';
import '../../../../domain/entities/media_item.dart';
import '../../../widgets/common/authenticated_image.dart';

class MediaThumbnail extends StatelessWidget {
  final MediaItemEntity item;

  const MediaThumbnail({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/viewer/${item.id}'),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AuthenticatedImage(
              imageUrl: item.thumbnailUrl,
              accountId: item.accountId,
              cacheKey: 'media:${item.id}',
              fit: BoxFit.cover,
            ),
            if (item.mediaType == MediaType.video)
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow,
                          color: Colors.white, size: 12),
                      const SizedBox(width: 2),
                      Text(
                        item.formattedDuration,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
