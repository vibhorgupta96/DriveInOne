import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/entities/face_cluster.dart';
import '../../../providers/face_providers.dart';
import '../../../widgets/common/authenticated_image.dart';

class PersonCircle extends ConsumerWidget {
  final FaceClusterEntity cluster;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAddName;

  const PersonCircle({
    super.key,
    required this.cluster,
    this.onTap,
    this.onLongPress,
    this.onAddName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final representativeFaceThumb = ref.watch(
      representativeFaceThumbnailProvider(cluster.id),
    );
    final representativeMedia = ref.watch(
      representativeMediaProvider(cluster.id),
    );
    final showAddName = cluster.label == null || cluster.label!.trim().isEmpty;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipOval(
                    child: representativeFaceThumb.when(
                      data: (faceBytes) {
                        if (faceBytes != null && faceBytes.isNotEmpty) {
                          return Image.memory(
                            faceBytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => _fallbackMediaThumb(
                              context,
                              representativeMedia,
                            ),
                          );
                        }
                        return _fallbackMediaThumb(
                          context,
                          representativeMedia,
                        );
                      },
                      loading: () =>
                          _fallbackMediaThumb(context, representativeMedia),
                      error: (_, _) =>
                          _fallbackMediaThumb(context, representativeMedia),
                    ),
                  ),
                ),
                if (onAddName != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onAddName,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            showAddName ? Icons.person_add_alt_1 : Icons.edit,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 96,
            child: Text(
              showAddName ? 'Add name' : cluster.displayName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: showAddName
                    ? Theme.of(context).colorScheme.primary
                    : null,
                fontWeight: showAddName ? FontWeight.w600 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: 96,
            child: Text(
              '${cluster.faceCount} appearances',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackMediaThumb(
    BuildContext context,
    AsyncValue<dynamic> representativeMedia,
  ) {
    return representativeMedia.when(
      data: (media) {
        if (media == null) return _placeholder(context);
        return AuthenticatedImage(
          imageUrl: media.thumbnailUrl,
          accountId: media.accountId,
          cacheKey:
              '${media.accountId}|${media.id}|${media.fileHash ?? media.syncedAt.microsecondsSinceEpoch}',
          fit: BoxFit.cover,
        );
      },
      loading: () => _placeholder(context),
      error: (_, _) => _placeholder(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(
        Icons.person,
        size: 40,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    );
  }
}
