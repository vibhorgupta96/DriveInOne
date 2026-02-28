import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/entities/face_cluster.dart';
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
    final clusters = ref.watch(peopleProvider);
    final clusterList = clusters.value;
    FaceClusterEntity? cluster;
    if (clusterList != null) {
      for (final item in clusterList) {
        if (item.id == clusterId) {
          cluster = item;
          break;
        }
      }
    }
    final title = cluster?.displayName ?? 'Person';
    final currentLabel = cluster?.label ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: currentLabel.trim().isEmpty ? 'Add name' : 'Rename',
            onPressed: () => _showRenameDialog(context, ref, currentLabel),
          ),
        ],
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
                if (currentLabel.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _showRenameDialog(context, ref, currentLabel),
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Add name'),
                      ),
                    ),
                  ),
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

  void _showRenameDialog(BuildContext context, WidgetRef ref, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(currentName.trim().isEmpty ? 'Add Name' : 'Rename Person'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                ref.read(faceRepositoryProvider.future).then(
                  (repo) => repo.renameCluster(clusterId, name),
                ).catchError((_) {});
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
