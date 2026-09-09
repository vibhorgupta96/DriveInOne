import 'dart:async';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums/provider_type.dart';
import '../../core/extensions/enum_converters.dart';
import '../../core/errors/exceptions.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/sync_status.dart';
import '../../domain/repositories/sync_repository.dart';
import '../database/app_database.dart';
import '../database/daos/accounts_dao.dart';
import '../database/daos/media_items_dao.dart';
import '../datasources/cloud/cloud_provider.dart';
import '../datasources/cloud/dropbox_provider.dart';
import '../datasources/local/secure_storage_source.dart';
import '../datasources/local/account_operation_gate.dart';
import '../models/media_item_model.dart';
import '../models/sync_result_model.dart';

class SyncRepositoryImpl implements SyncRepository {
  final Map<ProviderType, CloudProviderFactory> providerFactories;
  final AccountsDao accountsDao;
  final MediaItemsDao mediaItemsDao;
  final SecureStorageSource secureStorage;

  final _syncStatusController = StreamController<SyncStatus>.broadcast();
  final _uuid = const Uuid();

  SyncRepositoryImpl({
    required this.providerFactories,
    required this.accountsDao,
    required this.mediaItemsDao,
    required this.secureStorage,
  });

  @override
  Stream<SyncStatus> watchSyncStatus() => _syncStatusController.stream;

  CloudProvider _createProvider(ProviderType type, String accountId) {
    final factory = providerFactories[type];
    if (factory == null) {
      throw SyncException(message: 'No provider for $type');
    }
    return factory(accountId: accountId);
  }

  @override
  Future<SyncResult> syncAccount(String accountId) async {
    final operationGeneration = AccountOperationGate.beginSync(accountId);
    _syncStatusController.add(SyncStatus.syncing(accountId: accountId));

    try {
      final account = await accountsDao.getAccountById(accountId);
      if (account == null) {
        throw const SyncException(message: 'Account not found');
      }

      final providerType = account.providerType.toDomain();
      final provider = _createProvider(providerType, accountId);

      // Restore tokens
      final accessToken = await secureStorage.getAccessToken(accountId);
      final refreshToken = await secureStorage.getRefreshToken(accountId);
      final expiry = await secureStorage.getTokenExpiry(accountId);
      AppLogger.info(
        'Sync: restoring tokens for $accountId (token ${accessToken != null ? "found" : "missing"}, expiry: $expiry)',
      );

      if (accessToken != null) {
        provider.setTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
        );
      } else {
        throw const SyncException(message: 'No access token found for account');
      }

      await provider.refreshTokenIfNeeded();

      if (!AccountOperationGate.isCurrent(accountId, operationGeneration)) {
        return _cancelledSyncResult();
      }

      // Save refreshed tokens + expiry back (use provider's current values,
      // not the stale locals, in case refreshTokenIfNeeded updated them)
      if (provider.accessToken != null) {
        await AccountOperationGate.runIfCurrent(
          accountId,
          operationGeneration,
          () => secureStorage.saveTokens(
            accountId: accountId,
            accessToken: provider.accessToken!,
            refreshToken: provider.refreshToken,
            expiry: provider.tokenExpiry,
          ),
        );
      }

      // Perform delta sync
      final result = await provider.scanDelta(account.syncToken);
      AppLogger.info(
        'Sync: scanDelta returned ${result.changedItems.length} items, ${result.deletedRemoteIds.length} deleted',
      );

      // The account can be unlinked while scanDelta is awaiting the network.
      // Never apply that old response after a lifecycle generation changes.
      final accountBeforeApply = await accountsDao.getAccountById(accountId);
      if (!AccountOperationGate.isCurrent(accountId, operationGeneration) ||
          accountBeforeApply == null) {
        AppLogger.info(
          'Sync response discarded for retired account $accountId',
        );
        return _cancelledSyncResult();
      }

      // Delta pages are chronological event streams. Normalize each remote
      // item to its final event before writing so both delete->restore and
      // restore->delete retain their last state.
      final deletedKeys = <String>{...result.deletedRemoteIds};
      final changedItems = <String, MediaItemModel>{};
      final events = result.orderedEvents.isEmpty
          ? <SyncDeltaEvent>[
              // Legacy custom providers did not expose event order. Preserve
              // their established restore-friendly result behavior.
              ...result.deletedRemoteIds.map(SyncDeltaEvent.deleted),
              ...result.changedItems.map(SyncDeltaEvent.changed),
            ]
          : result.orderedEvents;
      for (final event in events) {
        final item = event.changedItem;
        if (item == null) {
          final deletedKey = event.deletedRemoteId;
          if (deletedKey == null) continue;
          deletedKeys.add(deletedKey);
          final deletedPath = DropboxProvider.pathFromDeletionKey(deletedKey);
          changedItems.remove(deletedKey);
          if (deletedPath != null) {
            changedItems.removeWhere(
              (_, changed) =>
                  changed.remotePath == deletedPath ||
                  (changed.remotePath?.startsWith('$deletedPath/') ?? false),
            );
          }
          continue;
        }
        changedItems[item.remoteId] = item;
        deletedKeys.remove(item.remoteId);
        if (item.remotePath != null) {
          deletedKeys.remove(
            DropboxProvider.deletionKeyForPath(item.remotePath!),
          );
        }
      }

      // Upsert changed items in batches within a transaction for performance.
      // Only the final per-remote-id state should be reported to callers.
      const batchSize = 50;
      final finalChanges = changedItems.values.toList();
      // Apply folder tombstones first. A later child restore in the same
      // ordered stream is then upserted below, while untouched siblings stay
      // deleted. Removing the parent tombstone here would resurrect siblings.
      final committed = await AccountOperationGate.runIfCurrent(
        accountId,
        operationGeneration,
        () => mediaItemsDao.transaction(() async {
          // Validation and all local delta mutations share this transaction.
          // An unlink queues its purge behind any already-active commit.
          if (await accountsDao.getAccountById(accountId) == null) return null;
          final initiallyActiveIds = (await mediaItemsDao.getMediaByAccount(
            accountId,
          )).map((item) => item.id).toSet();
          if (deletedKeys.isNotEmpty) {
            final deletionKeys = deletedKeys.map((key) {
              final dropboxPath = DropboxProvider.pathFromDeletionKey(key);
              return dropboxPath == null ? key : 'path:$dropboxPath';
            }).toList();
            await mediaItemsDao.batchMarkDeleted(accountId, deletionKeys);
          }
          for (var i = 0; i < finalChanges.length; i += batchSize) {
            final end = (i + batchSize).clamp(0, finalChanges.length);
            final batch = finalChanges.sublist(i, end);

            await mediaItemsDao.batchUpsert(
              batch.map((item) {
                final mediaId = _uuid.v5(
                  Namespace.url.value,
                  '$accountId|${item.remoteId}',
                );
                return MediaItemsCompanion(
                  id: Value(mediaId),
                  accountId: Value(accountId),
                  remoteId: Value(item.remoteId),
                  remotePath: Value(item.remotePath),
                  fileName: Value(item.fileName),
                  mimeType: Value(item.mimeType),
                  mediaType: Value(item.mediaType.toDbEnum()),
                  thumbnailUrl: Value(item.thumbnailUrl),
                  fullSizeUrl: Value(item.fullSizeUrl),
                  width: Value(item.width),
                  height: Value(item.height),
                  fileSize: Value(item.fileSize),
                  durationSeconds: Value(item.durationSeconds),
                  fileHash: Value(item.fileHash),
                  timestamp: Value(item.timestamp),
                  isDeleted: const Value(false),
                );
              }).toList(),
            );
          }

          if (result.isFullSnapshot) {
            // A cursor reset/root scan is authoritative only after every page has
            // arrived. Reconcile stale local rows now, never during a failed
            // partial fetch.
            final presentIds = finalChanges.map((item) => item.remoteId);
            await mediaItemsDao.reconcileFullSnapshot(accountId, presentIds);
          }

          // Count records whose final state became deleted. This accounts for
          // folder tombstone descendants and reconciliation, without counting
          // a delete followed by a restore or duplicate provider events.
          final finalActiveIds = (await mediaItemsDao.getMediaByAccount(
            accountId,
          )).map((item) => item.id).toSet();
          final actualDeleted = initiallyActiveIds
              .where((id) => !finalActiveIds.contains(id))
              .length;
          // Update sync token
          await accountsDao.updateSyncToken(accountId, result.newSyncToken);
          return _CommittedSyncCounts(
            itemsSynced: finalChanges.length,
            itemsDeleted: actualDeleted,
          );
        }),
      );
      if (committed == null) {
        return _cancelledSyncResult();
      }

      final total = committed.itemsSynced + committed.itemsDeleted;
      _syncStatusController.add(
        SyncStatus.syncing(accountId: accountId, synced: total, total: total),
      );
      _syncStatusController.add(SyncStatus.idle(lastSync: DateTime.now()));
      AppLogger.info(
        'Sync complete for $accountId: ${committed.itemsSynced} changed, ${committed.itemsDeleted} deleted',
      );

      return SyncResult(
        itemsSynced: committed.itemsSynced,
        itemsDeleted: committed.itemsDeleted,
        accountOutcomes: [
          AccountSyncOutcome.success(
            accountId: accountId,
            accountLabel: account.email,
            itemsSynced: committed.itemsSynced,
            itemsDeleted: committed.itemsDeleted,
          ),
        ],
      );
    } catch (e) {
      AppLogger.error('Sync failed for $accountId', error: e);
      _syncStatusController.add(SyncStatus.error(e.toString()));
      rethrow;
    }
  }

  SyncResult _cancelledSyncResult() {
    // A lifecycle generation can retire while this operation awaits network
    // I/O. Clear its visible syncing state before returning its no-op result.
    _syncStatusController.add(const SyncStatus.idle());
    return const SyncResult(itemsSynced: 0, itemsDeleted: 0);
  }

  @override
  Future<SyncResult> syncAllAccounts() async {
    final accounts = await accountsDao.getAllAccounts();
    int totalSynced = 0;
    int totalDeleted = 0;
    final outcomes = <AccountSyncOutcome>[];

    for (final account in accounts) {
      try {
        final result = await syncAccount(account.id);
        totalSynced += result.itemsSynced;
        totalDeleted += result.itemsDeleted;
        outcomes.addAll(result.accountOutcomes);
      } catch (e, st) {
        AppLogger.error(
          'Sync failed for ${account.id}',
          error: e,
          stackTrace: st,
        );
        outcomes.add(
          AccountSyncOutcome.failure(
            accountId: account.id,
            accountLabel: account.email,
            error: e is AppException ? e.message : e.toString(),
          ),
        );
      }
    }

    final failedCount = outcomes.where((outcome) => !outcome.succeeded).length;
    if (failedCount > 0) {
      _syncStatusController.add(
        SyncStatus.error(
          '$failedCount account${failedCount == 1 ? '' : 's'} failed to sync',
        ),
      );
    } else {
      _syncStatusController.add(SyncStatus.idle(lastSync: DateTime.now()));
    }

    return SyncResult(
      itemsSynced: totalSynced,
      itemsDeleted: totalDeleted,
      accountOutcomes: outcomes,
    );
  }

  @override
  Future<void> refreshAllTokens({bool silentOnly = false}) async {
    final accounts = await accountsDao.getAllAccounts();
    for (final account in accounts) {
      try {
        final providerType = account.providerType.toDomain();
        final operationGeneration = AccountOperationGate.generationFor(
          account.id,
        );

        final provider = _createProvider(providerType, account.id);

        final accessToken = await secureStorage.getAccessToken(account.id);
        final refreshToken = await secureStorage.getRefreshToken(account.id);
        final expiry = await secureStorage.getTokenExpiry(account.id);

        if (accessToken == null) {
          AppLogger.error('Token refresh: no token for ${account.id}');
          continue;
        }

        provider.setTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
        );
        await provider.refreshTokenIfNeeded();

        if (provider.accessToken != null &&
            AccountOperationGate.isCurrent(account.id, operationGeneration)) {
          await AccountOperationGate.runIfCurrent(
            account.id,
            operationGeneration,
            () => secureStorage.saveTokens(
              accountId: account.id,
              accessToken: provider.accessToken!,
              refreshToken: provider.refreshToken ?? refreshToken,
              expiry: provider.tokenExpiry,
            ),
          );
          AppLogger.info('Token refresh: refreshed token for ${account.id}');
        }
      } catch (e) {
        AppLogger.error('Token refresh failed for ${account.id}', error: e);
      }
    }
  }

  void dispose() {
    _syncStatusController.close();
  }
}

class _CommittedSyncCounts {
  const _CommittedSyncCounts({
    required this.itemsSynced,
    required this.itemsDeleted,
  });

  final int itemsSynced;
  final int itemsDeleted;
}
