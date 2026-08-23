import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/utils/logger.dart';
import '../../providers/face_providers.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/error_widget.dart';
import '../../widgets/common/loading_indicator.dart';
import 'widgets/person_circle.dart';

class PeopleScreen extends ConsumerWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clusters = ref.watch(peopleProvider);
    final progress = ref.watch(pipelineProgressProvider);
    final scanState = ref.watch(faceScanNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'View logs',
            onPressed: () => _showLogViewer(context),
          ),
          if (scanState.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.face_retouching_natural),
              tooltip: 'Scan faces',
              onPressed: () =>
                  ref.read(faceScanNotifierProvider.notifier).startScan(),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'reset') {
                  _showResetConfirmation(context, ref);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'reset',
                  child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('Reset & Re-scan'),
                    subtitle: Text('Clear all face data and rescan'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Progress bar
          progress.when(
            data: (p) {
              if (!p.isRunning) return const SizedBox.shrink();
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Scanning faces: ${p.processed} / ${p.total}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: p.fraction,
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          // Error display
          if (scanState.hasError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Face scan error: ${scanState.error}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ),
          // People grid
          Expanded(
            child: clusters.when(
              data: (people) {
                if (people.isEmpty) {
                  final isProcessing = scanState.isLoading ||
                      (progress.value?.isRunning ?? false);
                  return EmptyState(
                    icon: Icons.people_outlined,
                    title: isProcessing
                        ? 'Scanning your photos...'
                        : 'No people found yet',
                    subtitle: isProcessing
                        ? 'People will appear here as faces are detected.'
                        : 'Tap the face icon above to scan your photos for faces.',
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: people.length,
                  itemBuilder: (context, index) {
                    final person = people[index];
                    return PersonCircle(
                      cluster: person,
                      onTap: () => context.push('/people/${person.id}'),
                      onLongPress: () => _showRenameDialog(
                          context, ref, person.id, person.displayName),
                      onAddName: () => _showRenameDialog(
                          context, ref, person.id, person.label ?? ''),
                    );
                  },
                );
              },
              loading: () => const LoadingIndicator(),
              error: (error, _) => ErrorDisplayWidget(error: error),
            ),
          ),
        ],
      ),
    );
  }

  void _showLogViewer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Text('Debug Logs',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    tooltip: 'Copy all',
                    onPressed: () {
                      final text =
                          AppLogger.entries.map((e) => e.formatted).join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Logs copied to clipboard')),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Clear',
                    onPressed: () {
                      AppLogger.clearLogs();
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: AppLogger.logNotifier,
                builder: (context, _, __) {
                  final logs = AppLogger.entries;
                  if (logs.isEmpty) {
                    return const Center(
                        child: Text('No logs yet. Tap the face scan button.'));
                  }
                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final entry = logs.elementAt(index);
                      final isError = entry.level == 'ERROR';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          entry.formatted,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: isError
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showResetConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset & Re-scan'),
        content: const Text(
          'This will clear all detected faces and clusters, then re-scan all your photos from scratch.\n\n'
          'This is useful if a previous scan was incomplete or had errors.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(faceScanNotifierProvider.notifier).resetAndRescan();
            },
            child: const Text('Reset & Re-scan'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, String clusterId,
      String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Person'),
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
                ref
                    .read(faceRepositoryProvider.future)
                    .then(
                      (repo) => repo.renameCluster(clusterId, name),
                    )
                    .catchError((_) {});
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
