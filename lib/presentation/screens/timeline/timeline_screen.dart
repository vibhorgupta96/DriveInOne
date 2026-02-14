import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/extensions/date_extensions.dart';
import '../../../domain/entities/media_item.dart';
import '../../providers/media_providers.dart';
import '../../providers/sync_providers.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/error_widget.dart';
import '../../widgets/common/loading_indicator.dart';
import 'widgets/media_grid.dart';
import 'widgets/timeline_group.dart';

class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(timelineProvider);
    final syncState = ref.watch(syncNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('DriveInOne'),
        actions: [
          if (syncState.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(syncNotifierProvider.notifier).syncAll(),
              tooltip: 'Sync all accounts',
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncNotifierProvider.notifier).syncAll(),
        child: timeline.when(
          data: (items) {
            if (items.isEmpty) {
              return const EmptyState(
                icon: Icons.photo_library_outlined,
                title: 'No photos yet',
                subtitle: 'Link a cloud account in Settings and sync to see your photos here.',
              );
            }
            return _buildTimeline(items);
          },
          loading: () => const LoadingIndicator(message: 'Loading your photos...'),
          error: (error, _) => ErrorDisplayWidget(
            error: error,
            onRetry: () => ref.invalidate(timelineProvider),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline(List<MediaItemEntity> items) {
    // Group items by date
    final groups = <String, List<MediaItemEntity>>{};
    for (final item in items) {
      final label = item.timestamp.timelineGroupLabel;
      groups.putIfAbsent(label, () => []).add(item);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final label = groups.keys.elementAt(index);
        final groupItems = groups[label]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TimelineGroup(label: label, count: groupItems.length),
            MediaGrid(items: groupItems),
          ],
        );
      },
    );
  }
}
