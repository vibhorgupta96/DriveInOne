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
          'Sync: restoring tokens for $accountId (token ${accessToken != null ? "found" : "missing"}, expiry: $expiry)');

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

      // Save refreshed tokens + expiry back (use provider's current values,
      // not the stale locals, in case refreshTokenIfNeeded updated them)
      if (provider.accessToken != null) {
        await secureStorage.saveTokens(
          accountId: accountId,
          accessToken: provider.accessToken!,
          refreshToken: provider.refreshToken,
          expiry: provider.tokenExpiry,
        );
      }

      // Perform delta sync
      final result = await provider.scanDelta(account.syncToken);
      AppLogger.info(
          'Sync: scanDelta returned ${result.changedItems.length} items, ${result.deletedRemoteIds.length} deleted');

      int synced = 0;
      final total = result.changedItems.length + result.deletedRemoteIds.length;

      // Upsert changed items in batches within a transaction for performance
      const batchSize = 50;
      for (var i = 0; i < result.changedItems.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, result.changedItems.length);
        final batch = result.changedItems.sublist(i, end);

        await mediaItemsDao.batchUpsert(batch.map((item) {
          final mediaId =
              _uuid.v5(Namespace.url.value, '$accountId|${item.remoteId}');
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
        }).toList());

        synced += batch.length;
        _syncStatusController.add(SyncStatus.syncing(
          accountId: accountId,
          synced: synced,
          total: total,
        ));
      }

      // Mark deleted items
      if (result.deletedRemoteIds.isNotEmpty) {
        final deletionKeys = result.deletedRemoteIds.map((key) {
          final dropboxPath = DropboxProvider.pathFromDeletionKey(key);
          return dropboxPath == null ? key : 'path:$dropboxPath';
        }).toList();
        await mediaItemsDao.batchMarkDeleted(accountId, deletionKeys);
        synced += result.deletedRemoteIds.length;
      }

      // Update sync token
      await accountsDao.updateSyncToken(accountId, result.newSyncToken);

      _syncStatusController.add(SyncStatus.idle(lastSync: DateTime.now()));
      AppLogger.info(
          'Sync complete for $accountId: ${result.changedItems.length} changed, ${result.deletedRemoteIds.length} deleted');

      return SyncResult(
        itemsSynced: result.changedItems.length,
        itemsDeleted: result.deletedRemoteIds.length,
        accountOutcomes: [
          AccountSyncOutcome.success(
            accountId: accountId,
            accountLabel: account.email,
            itemsSynced: result.changedItems.length,
            itemsDeleted: result.deletedRemoteIds.length,
          ),
        ],
      );
    } catch (e) {
      AppLogger.error('Sync failed for $accountId', error: e);
      _syncStatusController.add(SyncStatus.error(e.toString()));
      rethrow;
    }
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
        AppLogger.error('Sync failed for ${account.id}',
            error: e, stackTrace: st);
        outcomes.add(AccountSyncOutcome.failure(
          accountId: account.id,
          accountLabel: account.email,
          error: e is AppException ? e.message : e.toString(),
        ));
      }
    }

    final failedCount = outcomes.where((outcome) => !outcome.succeeded).length;
    if (failedCount > 0) {
      _syncStatusController.add(
        SyncStatus.error(
            '$failedCount account${failedCount == 1 ? '' : 's'} failed to sync'),
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

        final provider = _createProvider(providerType, account.id);

        final accessToken = await secureStorage.getAccessToken(account.id);
        final refreshToken = await secureStorage.getRefreshToken(account.id);
        final expiry = await secureStorage.getTokenExpiry(account.id);

        if (accessToken == null) {
          AppLogger.error('Token refresh: no token for ${account.id}');
          continue;
        }

        // In silent-only mode, skip Google accounts that lack a refresh token
        // because the Google Sign-In SDK fallback may show an account picker.
        if (silentOnly &&
            providerType == ProviderType.google &&
            refreshToken == null) {
          AppLogger.info(
              'Token refresh: skipping Google account ${account.id} (no refresh token, silent-only)');
          continue;
        }

        provider.setTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
        );
        await provider.refreshTokenIfNeeded();

        if (provider.accessToken != null) {
          await secureStorage.saveTokens(
            accountId: account.id,
            accessToken: provider.accessToken!,
            refreshToken: provider.refreshToken ?? refreshToken,
            expiry: provider.tokenExpiry,
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
