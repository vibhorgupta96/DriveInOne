import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/theme/app_colors.dart';
import '../../providers/auth_providers.dart';
import '../../providers/sync_providers.dart';
import '../../providers/media_providers.dart';
import '../../widgets/common/loading_indicator.dart';
import 'widgets/account_tile.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(linkedAccountsProvider);
    final syncState = ref.watch(syncNotifierProvider);
    final linkState = ref.watch(linkAccountProvider);
    final mediaCount = ref.watch(mediaCountProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Linked Accounts section
          _sectionHeader(context, 'Linked Accounts'),
          accounts.when(
            data: (accts) {
              if (accts.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No accounts linked yet. Add a cloud account to get started.',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return Column(
                children: accts.map((a) => AccountTile(
                  account: a,
                  onUnlink: () => _confirmUnlink(context, ref, a.id, a.email),
                )).toList(),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: LoadingIndicator(),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $e'),
            ),
          ),

          const Divider(height: 1),

          // Add Account buttons
          if (linkState.isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LoadingIndicator(message: 'Connecting account...'),
            )
          else ...[
            _addAccountTile(
              context, ref,
              'Link Google Drive',
              Icons.cloud,
              AppColors.googleDrive,
              ProviderType.google,
            ),
            _addAccountTile(
              context, ref,
              'Link OneDrive',
              Icons.cloud_queue,
              AppColors.oneDrive,
              ProviderType.onedrive,
            ),
            _addAccountTile(
              context, ref,
              'Link Dropbox',
              Icons.cloud_circle,
              AppColors.dropbox,
              ProviderType.dropbox,
            ),
          ],

          const Divider(height: 32),

          // Sync section
          _sectionHeader(context, 'Sync'),
          ListTile(
            leading: syncState.isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            title: const Text('Sync Now'),
            subtitle: const Text('Fetch new photos and videos from all accounts'),
            onTap: syncState.isLoading
                ? null
                : () => ref.read(syncNotifierProvider.notifier).syncAll(),
          ),
          mediaCount.when(
            data: (count) => ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Total Media Items'),
              trailing: Text(
                '$count',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          const Divider(height: 32),

          // About section
          _sectionHeader(context, 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('DriveInOne'),
            subtitle: Text('Version 1.0.0'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _addAccountTile(
    BuildContext context,
    WidgetRef ref,
    String title,
    IconData icon,
    Color color,
    ProviderType type,
  ) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      trailing: const Icon(Icons.add),
      onTap: () => ref.read(linkAccountProvider.notifier).link(type),
    );
  }

  void _confirmUnlink(BuildContext context, WidgetRef ref, String accountId, String email) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink Account'),
        content: Text('Are you sure you want to unlink $email? Media from this account will be removed from the gallery.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(linkAccountProvider.notifier).unlink(accountId);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
  }
}
