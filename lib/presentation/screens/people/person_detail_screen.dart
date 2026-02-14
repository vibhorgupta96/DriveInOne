import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/face_providers.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/error_widget.dart';
import '../../widgets/common/loading_indicator.dart';
import '../timeline/widgets/media_grid.dart';

class PersonDetailScreen extends ConsumerWidget {
  final String clusterId;

  const PersonDetailScreen({super.key, required this.clusterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(mediaForPersonProvider(clusterId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Person'),
      ),
      body: media.when(
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.photo_outlined,
              title: 'No photos found',
            );
          }
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '${items.length} photos & videos',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                MediaGrid(items: items),
              ],
            ),
          );
        },
        loading: () => const LoadingIndicator(),
        error: (error, _) => ErrorDisplayWidget(error: error),
      ),
    );
  }
}
