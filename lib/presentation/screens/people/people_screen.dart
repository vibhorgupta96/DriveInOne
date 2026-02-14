import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('People')),
      body: clusters.when(
        data: (people) {
          if (people.isEmpty) {
            return const EmptyState(
              icon: Icons.people_outlined,
              title: 'No people found yet',
              subtitle: 'Face recognition will detect people in your photos after syncing.',
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 0.8,
            ),
            itemCount: people.length,
            itemBuilder: (context, index) {
              final person = people[index];
              return PersonCircle(
                cluster: person,
                onTap: () => context.push('/people/${person.id}'),
                onLongPress: () => _showRenameDialog(context, ref, person.id, person.displayName),
              );
            },
          );
        },
        loading: () => const LoadingIndicator(),
        error: (error, _) => ErrorDisplayWidget(error: error),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, String clusterId, String currentName) {
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
                try {
                  ref.read(faceRepositoryProvider).renameCluster(clusterId, name);
                } catch (_) {}
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
