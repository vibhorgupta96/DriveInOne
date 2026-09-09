import 'package:flutter/material.dart';
import '../../../../domain/entities/sync_status.dart';

class SyncStatusTile extends StatelessWidget {
  final SyncStatus? status;

  const SyncStatusTile({super.key, this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) {
      return const ListTile(
        leading: Icon(Icons.sync_disabled),
        title: Text('Not synced'),
        subtitle: Text('Tap Sync Now to start'),
      );
    }

    if (status!.isSyncing) {
      return ListTile(
        leading: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: const Text('Syncing...'),
        subtitle: status!.totalItems > 0
            ? Text('${status!.itemsSynced} / ${status!.totalItems} items')
            : null,
      );
    }

    if (status!.error != null) {
      return ListTile(
        leading: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const Text('Sync error'),
        subtitle: Text(
          status!.error!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return ListTile(
      leading: const Icon(Icons.check_circle_outline, color: Colors.green),
      title: const Text('Synced'),
      subtitle: status!.lastSyncTime != null
          ? Text('Last: ${status!.lastSyncTime.toString().split('.').first}')
          : null,
    );
  }
}
