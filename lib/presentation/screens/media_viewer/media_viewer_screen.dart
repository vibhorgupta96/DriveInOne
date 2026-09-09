import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/enums/media_type.dart';
import '../../providers/media_providers.dart';
import '../../widgets/common/loading_indicator.dart';
import '../../widgets/common/error_widget.dart';
import 'widgets/photo_viewer.dart';
import 'widgets/video_player_widget.dart';

class MediaViewerScreen extends ConsumerWidget {
  final String mediaId;

  const MediaViewerScreen({super.key, required this.mediaId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider(mediaId));

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfoSheet(context, ref),
          ),
        ],
      ),
      body: mediaItem.when(
        data: (item) {
          if (item == null) {
            return const ErrorDisplayWidget(error: 'Media item not found');
          }
          if (item.mediaType == MediaType.photo) {
            return PhotoViewer(mediaItem: item);
          } else {
            return SecureVideoPlayer(mediaItem: item);
          }
        },
        loading: () => const LoadingIndicator(),
        error: (error, _) => ErrorDisplayWidget(error: error),
      ),
    );
  }

  void _showInfoSheet(BuildContext context, WidgetRef ref) {
    final item = ref.read(mediaItemProvider(mediaId)).value;
    if (item == null) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.fileName, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _infoRow('Type', item.mediaType.displayName),
            if (item.width != null && item.height != null)
              _infoRow('Resolution', '${item.width} x ${item.height}'),
            if (item.formattedFileSize.isNotEmpty)
              _infoRow('Size', item.formattedFileSize),
            if (item.durationSeconds != null)
              _infoRow('Duration', item.formattedDuration),
            _infoRow('Date', item.timestamp.toString().split('.').first),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
