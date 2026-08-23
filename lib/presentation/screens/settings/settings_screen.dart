import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/account.dart';
import '../../../domain/repositories/sync_repository.dart';
import '../../providers/auth_providers.dart';
import '../../providers/sync_providers.dart';
import '../../providers/media_providers.dart';
import '../../widgets/common/loading_indicator.dart';
import '../../widgets/common/provider_icon.dart';
import 'widgets/account_tile.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfo;

  @override
  void initState() {
    super.initState();
    _packageInfo = PackageInfo.fromPlatform();
  }

  void _showSyncResult(SyncResult result) {
    if (!mounted) return;
    final failed = result.failedAccounts;
    final successful = result.successfulAccounts;
    late final String message;
    Color? backgroundColor;

    if (result.accountOutcomes.isEmpty) {
      message = 'No linked accounts to sync.';
    } else if (result.allFailed) {
      message = 'Sync failed for ${failed.length} '
          'account${failed.length == 1 ? '' : 's'}: ${_failureSummary(failed)}';
      backgroundColor = AppColors.error;
    } else if (result.isPartialSuccess) {
      message = 'Synced ${result.itemsSynced} items'
          '${result.itemsDeleted > 0 ? ', removed ${result.itemsDeleted}' : ''}. '
          '${failed.length} of ${result.accountOutcomes.length} accounts failed: '
          '${_failureSummary(failed)}';
      backgroundColor = AppColors.warning;
    } else if (result.itemsSynced == 0 && result.itemsDeleted == 0) {
      message = '${successful.length} '
          'account${successful.length == 1 ? ' is' : 's are'} up to date.';
    } else {
      message = 'Synced ${result.itemsSynced} items'
          '${result.itemsDeleted > 0 ? ', removed ${result.itemsDeleted}' : ''} '
          'from ${successful.length} account${successful.length == 1 ? '' : 's'}.';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: Duration(seconds: result.hasFailures ? 7 : 4),
      ),
    );
    ref.invalidate(mediaCountProvider);
    ref.invalidate(mediaStatsProvider);
  }

  String _failureSummary(List<AccountSyncOutcome> failed) {
    return failed
        .take(2)
        .map((outcome) =>
            '${outcome.accountLabel}: ${outcome.errorMessage ?? 'Unknown error'}')
        .join('; ');
  }

  void _showSyncError(Object error) {
    if (!mounted) return;
    final message = error is AppException ? error.message : error.toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sync failed: $message'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(linkedAccountsProvider);
    final syncState = ref.watch(syncNotifierProvider);
    final linkState = ref.watch(linkAccountProvider);
    final mediaCount = ref.watch(mediaCountProvider);

    ref.listen<AsyncValue<SyncResult?>>(syncNotifierProvider, (prev, next) {
      if (prev?.isLoading == true && !next.isLoading) {
        next.when(
          data: (result) {
            if (result != null) _showSyncResult(result);
          },
          error: (e, _) => _showSyncError(e),
          loading: () {},
        );
      }
    });

    ref.listen<AsyncValue<void>>(linkAccountProvider, (prev, next) {
      if (prev?.isLoading == true && next.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Account update failed: ${next.error}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Linked Accounts section
          _sectionHeader('Linked Accounts'),
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
                children: accts
                    .map((a) => AccountTile(
                          account: a,
                          onUnlink: () => _confirmUnlink(a.id, a.email),
                        ))
                    .toList(),
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
              'Link Google Drive',
              Icons.cloud,
              AppColors.googleDrive,
              ProviderType.google,
            ),
            _addAccountTile(
              'Link OneDrive',
              Icons.cloud_queue,
              AppColors.oneDrive,
              ProviderType.onedrive,
            ),
            _addAccountTile(
              'Link Dropbox',
              Icons.cloud_circle,
              AppColors.dropbox,
              ProviderType.dropbox,
            ),
          ],

          const Divider(height: 32),

          // Sync section
          _sectionHeader('Sync'),
          ListTile(
            leading: syncState.isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            title: const Text('Sync Now'),
            subtitle:
                const Text('Fetch new photos and videos from all accounts'),
            onTap: syncState.isLoading
                ? null
                : () => ref.read(syncNotifierProvider.notifier).syncAll(),
          ),
          mediaCount.when(
            data: (count) => ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Total Media Items'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              onTap: () => _showMediaStatsSheet(),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          const Divider(height: 32),

          // About section
          _sectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('DriveInOne'),
            subtitle: FutureBuilder<PackageInfo>(
              future: _packageInfo,
              builder: (context, snapshot) =>
                  Text('Version ${snapshot.data?.version ?? '0.0.1'}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
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

  void _showMediaStatsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final stats = ref.watch(mediaStatsProvider);
          final accounts = ref.watch(linkedAccountsProvider);

          return stats.when(
            data: (statsMap) {
              int totalPhotos = 0;
              int totalVideos = 0;
              for (final s in statsMap.values) {
                totalPhotos += s.photos;
                totalVideos += s.videos;
              }

              final accountList = accounts.value ?? [];

              return DraggableScrollableSheet(
                initialChildSize: 0.45,
                minChildSize: 0.3,
                maxChildSize: 0.7,
                expand: false,
                builder: (context, scrollController) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ListView(
                    controller: scrollController,
                    children: [
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Media Stats',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _statCard(
                              context,
                              Icons.photo_outlined,
                              '$totalPhotos',
                              'Photos',
                              AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _statCard(
                              context,
                              Icons.videocam_outlined,
                              '$totalVideos',
                              'Videos',
                              AppColors.accent,
                            ),
                          ),
                        ],
                      ),
                      if (accountList.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          'By Account',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        ...accountList.map((account) {
                          final accountStats = statsMap[account.id];
                          final photos = accountStats?.photos ?? 0;
                          final videos = accountStats?.videos ?? 0;
                          return _accountStatsRow(
                              context, account, photos, videos);
                        }),
                      ],
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              );
            },
            loading: () => const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SizedBox(
              height: 200,
              child: Center(child: Text('Failed to load stats: $e')),
            ),
          );
        },
      ),
    );
  }

  Widget _statCard(
    BuildContext context,
    IconData icon,
    String value,
    String label,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _accountStatsRow(
    BuildContext context,
    AccountEntity account,
    int photos,
    int videos,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ProviderIcon(providerType: account.providerType, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.email,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  account.providerType.displayName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.photo_outlined,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 2),
              Text('$photos', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 10),
              const Icon(
                Icons.videocam_outlined,
                size: 16,
                color: AppColors.accent,
              ),
              const SizedBox(width: 2),
              Text('$videos', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmUnlink(String accountId, String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink Account'),
        content: Text(
            'Are you sure you want to unlink $email? Media from this account will be removed from the gallery.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(linkAccountProvider.notifier).unlink(accountId);
              if (!mounted) return;
              final unlinkState = ref.read(linkAccountProvider);
              if (!unlinkState.hasError) {
                await ref.read(timelineNotifierProvider.notifier).refresh();
                ref.invalidate(mediaCountProvider);
                ref.invalidate(mediaStatsProvider);
                ref.invalidate(searchResultsProvider);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
  }
}
