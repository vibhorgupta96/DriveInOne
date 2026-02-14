import 'dart:async';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums/media_type.dart' as core_media;
import '../../core/enums/provider_type.dart';
import '../../core/errors/exceptions.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/sync_status.dart';
import '../../domain/repositories/sync_repository.dart';
import '../database/daos/accounts_dao.dart';
import '../database/daos/media_items_dao.dart';
import '../database/tables/accounts_table.dart';
import '../database/tables/media_items_table.dart';
import '../datasources/cloud/cloud_provider.dart';
import '../datasources/local/secure_storage_source.dart';

class SyncRepositoryImpl implements SyncRepository {
  final Map<ProviderType, CloudProvider> providers;
  final AccountsDao accountsDao;
  final MediaItemsDao mediaItemsDao;
  final SecureStorageSource secureStorage;

  final _syncStatusController = StreamController<SyncStatus>.broadcast();
  final _uuid = const Uuid();

  SyncRepositoryImpl({
    required this.providers,
    required this.accountsDao,
    required this.mediaItemsDao,
    required this.secureStorage,
  });

  ProviderType _enumToProviderType(ProviderTypeEnum e) {
    switch (e) {
      case ProviderTypeEnum.google:
        return ProviderType.google;
      case ProviderTypeEnum.onedrive:
        return ProviderType.onedrive;
      case ProviderTypeEnum.dropbox:
        return ProviderType.dropbox;
    }
  }

  ProviderTypeEnum _providerTypeToEnum(ProviderType type) {
    switch (type) {
      case ProviderType.google:
        return ProviderTypeEnum.google;
      case ProviderType.onedrive:
        return ProviderTypeEnum.onedrive;
      case ProviderType.dropbox:
        return ProviderTypeEnum.dropbox;
    }
  }

  @override
  Stream<SyncStatus> watchSyncStatus() => _syncStatusController.stream;

  @override
  Future<void> syncAccount(String accountId) async {
    _syncStatusController.add(SyncStatus.syncing(accountId: accountId));

    try {
      final account = await accountsDao.getAccountById(accountId);
      if (account == null) {
        throw const SyncException(message: 'Account not found');
      }

      final providerType = _enumToProviderType(account.providerType);
      final provider = providers[providerType];
      if (provider == null) {
        throw SyncException(message: 'No provider for $providerType');
      }

      // Restore tokens
      final accessToken = await secureStorage.getAccessToken(accountId);
      final refreshToken = await secureStorage.getRefreshToken(accountId);
      final expiry = await secureStorage.getTokenExpiry(accountId);
      if (accessToken != null) {
        provider.setTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
        );
      }

      await provider.refreshTokenIfNeeded();

      // Save refreshed tokens back
      if (provider.accessToken != null) {
        await secureStorage.saveTokens(
          accountId: accountId,
          accessToken: provider.accessToken!,
          refreshToken: refreshToken,
        );
      }

      // Perform delta sync
      final result = await provider.scanDelta(account.syncToken);

      int synced = 0;
      final total = result.changedItems.length + result.deletedRemoteIds.length;

      // Upsert changed items
      for (final item in result.changedItems) {
        final mediaId = _uuid.v5(Uuid.NAMESPACE_URL, '$accountId|${item.remoteId}');

        await mediaItemsDao.upsertMediaItem(MediaItemsCompanion(
          id: Value(mediaId),
          accountId: Value(accountId),
          remoteId: Value(item.remoteId),
          remotePath: Value(item.remotePath),
          fileName: Value(item.fileName),
          mimeType: Value(item.mimeType),
          mediaType: Value(item.mediaType == core_media.MediaType.photo
              ? MediaTypeEnum.photo
              : MediaTypeEnum.video),
          thumbnailUrl: Value(item.thumbnailUrl),
          fullSizeUrl: Value(item.fullSizeUrl),
          width: Value(item.width),
          height: Value(item.height),
          fileSize: Value(item.fileSize),
          durationSeconds: Value(item.durationSeconds),
          fileHash: Value(item.fileHash),
          timestamp: Value(item.timestamp),
          isDeleted: const Value(false),
        ));

        synced++;
        if (synced % 10 == 0) {
          _syncStatusController.add(SyncStatus.syncing(
            accountId: accountId,
            synced: synced,
            total: total,
          ));
        }
      }

      // Mark deleted items
      for (final remoteId in result.deletedRemoteIds) {
        await mediaItemsDao.markDeleted(accountId, remoteId);
        synced++;
      }

      // Update sync token
      await accountsDao.updateSyncToken(accountId, result.newSyncToken);

      _syncStatusController.add(SyncStatus.idle(lastSync: DateTime.now()));
      AppLogger.info('Sync complete for $accountId: ${result.changedItems.length} changed, ${result.deletedRemoteIds.length} deleted');
    } catch (e) {
      AppLogger.error('Sync failed for $accountId', error: e);
      _syncStatusController.add(SyncStatus.error(e.toString()));
      rethrow;
    }
  }

  @override
  Future<void> syncAllAccounts() async {
    final accounts = await accountsDao.getAllAccounts();

    for (final account in accounts) {
      try {
        await syncAccount(account.id);
      } catch (e) {
        AppLogger.error('Sync failed for ${account.id}', error: e);
        // Continue with next account
      }
    }
  }

  void dispose() {
    _syncStatusController.close();
  }
}
