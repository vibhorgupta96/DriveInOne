import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/sync_repository_impl.dart';
import '../../domain/entities/sync_status.dart';
import '../../domain/repositories/sync_repository.dart';
import 'auth_providers.dart';
import 'database_providers.dart';

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

final syncNotifierProvider = StateNotifierProvider<SyncNotifier, AsyncValue<void>>((ref) {
  return SyncNotifier(ref);
});

class SyncNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;

  SyncNotifier(this._ref) : super(const AsyncData(null));

  Future<void> syncAll() async {
    state = const AsyncLoading();
    try {
      await _ref.read(syncRepositoryProvider).syncAllAccounts();
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> syncAccount(String accountId) async {
    state = const AsyncLoading();
    try {
      await _ref.read(syncRepositoryProvider).syncAccount(accountId);
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}
