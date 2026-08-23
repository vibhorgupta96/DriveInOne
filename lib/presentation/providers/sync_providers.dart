import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/foreground_service_helper.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/sync_repository_impl.dart';
import '../../domain/entities/sync_status.dart';
import '../../domain/repositories/sync_repository.dart';
import 'auth_providers.dart';
import 'database_providers.dart';
import 'face_providers.dart';
import 'media_providers.dart';

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final repo = SyncRepositoryImpl(
    providerFactories: ref.watch(cloudProviderFactoriesProvider),
    accountsDao: db.accountsDao,
    mediaItemsDao: db.mediaItemsDao,
    secureStorage: ref.watch(secureStorageProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  return ref.watch(syncRepositoryProvider).watchSyncStatus();
});

final syncNotifierProvider =
    NotifierProvider<SyncNotifier, AsyncValue<SyncResult?>>(() {
  return SyncNotifier();
});

class SyncNotifier extends Notifier<AsyncValue<SyncResult?>> {
  bool _isSyncing = false;

  @override
  AsyncValue<SyncResult?> build() {
    return const AsyncData(null);
  }

  Future<void> syncAll() async {
    if (_isSyncing) return;
    _isSyncing = true;
    state = const AsyncLoading();
    try {
      try {
        await ForegroundServiceHelper.start(
          serviceId: 500,
          channelId: 'driveinone_sync',
          channelName: 'Sync Service',
          channelDescription: 'Syncing media from cloud accounts',
          notificationTitle: 'DriveInOne',
          notificationText: 'Syncing media from cloud...',
        );
      } catch (_) {}
      final result = await ref.read(syncRepositoryProvider).syncAllAccounts();
      await _refreshMediaViews();
      if (result.hasSuccessfulAccounts) {
        await _runFaceDetection();
      }
      state = AsyncData(result);
    } catch (e, st) {
      AppLogger.error('syncAll failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
    } finally {
      _isSyncing = false;
      try {
        await ForegroundServiceHelper.stop();
      } catch (_) {}
    }
  }

  Future<void> syncAccount(String accountId) async {
    if (_isSyncing) return;
    _isSyncing = true;
    state = const AsyncLoading();
    try {
      try {
        await ForegroundServiceHelper.start(
          serviceId: 500,
          channelId: 'driveinone_sync',
          channelName: 'Sync Service',
          channelDescription: 'Syncing media from cloud accounts',
          notificationTitle: 'DriveInOne',
          notificationText: 'Syncing media from cloud...',
        );
      } catch (_) {}
      final result =
          await ref.read(syncRepositoryProvider).syncAccount(accountId);
      await _refreshMediaViews();
      await _runFaceDetection();
      state = AsyncData(result);
    } catch (e, st) {
      AppLogger.error('syncAccount failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
    } finally {
      _isSyncing = false;
      try {
        await ForegroundServiceHelper.stop();
      } catch (_) {}
    }
  }

  Future<void> _runFaceDetection() async {
    try {
      final pipeline = await ref.read(aiPipelineProvider.future);
      await pipeline.processNewMedia();
    } catch (e) {
      AppLogger.error('Failed to start face detection', error: e);
    }
  }

  Future<void> _refreshMediaViews() async {
    try {
      await ref.read(timelineNotifierProvider.notifier).refresh();
      ref.invalidate(mediaCountProvider);
      ref.invalidate(mediaStatsProvider);
      ref.invalidate(searchResultsProvider);
    } catch (e, st) {
      AppLogger.error(
        'Failed to refresh media views after sync',
        error: e,
        stackTrace: st,
      );
    }
  }
}
