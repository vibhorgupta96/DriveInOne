import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/sync_repository_impl.dart';
import '../../domain/entities/sync_status.dart';
import '../../domain/repositories/sync_repository.dart';
import 'auth_providers.dart';
import 'database_providers.dart';
import 'face_providers.dart';

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return SyncRepositoryImpl(
    providers: ref.watch(cloudProvidersProvider),
    accountsDao: db.accountsDao,
    mediaItemsDao: db.mediaItemsDao,
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  return ref.watch(syncRepositoryProvider).watchSyncStatus();
});

final syncNotifierProvider = NotifierProvider<SyncNotifier, AsyncValue<SyncResult?>>(() {
  return SyncNotifier();
});

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'driveinone_sync',
      channelName: 'Sync Service',
      channelDescription: 'Syncing media from cloud accounts',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> _startForegroundService() async {
  _initForegroundTask();
  final notifPermission = await FlutterForegroundTask.checkNotificationPermission();
  if (notifPermission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  await FlutterForegroundTask.startService(
    serviceId: 500,
    notificationTitle: 'DriveInOne',
    notificationText: 'Syncing media from cloud...',
  );
}

Future<void> _stopForegroundService() async {
  await FlutterForegroundTask.stopService();
}

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
      try { await _startForegroundService(); } catch (_) {}
      final result = await ref.read(syncRepositoryProvider).syncAllAccounts();
      state = AsyncData(result);
      _runFaceDetection();
    } catch (e, st) {
      AppLogger.error('syncAll failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
    } finally {
      _isSyncing = false;
      try { await _stopForegroundService(); } catch (_) {}
    }
  }

  Future<void> syncAccount(String accountId) async {
    if (_isSyncing) return;
    _isSyncing = true;
    state = const AsyncLoading();
    try {
      try { await _startForegroundService(); } catch (_) {}
      final result = await ref.read(syncRepositoryProvider).syncAccount(accountId);
      state = AsyncData(result);
      _runFaceDetection();
    } catch (e, st) {
      AppLogger.error('syncAccount failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
    } finally {
      _isSyncing = false;
      try { await _stopForegroundService(); } catch (_) {}
    }
  }

  Future<void> _runFaceDetection() async {
    try {
      final pipeline = await ref.read(aiPipelineProvider.future);
      pipeline.processNewMedia();
    } catch (e) {
      AppLogger.error('Failed to start face detection', error: e);
    }
  }
}
