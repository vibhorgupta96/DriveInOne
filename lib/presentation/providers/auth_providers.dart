import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/enums/provider_type.dart';
import '../../core/utils/logger.dart';
import '../../data/datasources/cloud/cloud_provider.dart';
import '../../data/datasources/cloud/google_drive_provider.dart';
import '../../data/datasources/cloud/onedrive_provider.dart';
import '../../data/datasources/cloud/dropbox_provider.dart';
import '../../data/repositories/auth_repository_impl.dart';
import '../../domain/entities/account.dart';
import '../../domain/repositories/auth_repository.dart';
import 'database_providers.dart';
import 'sync_providers.dart';

final cloudProvidersProvider = Provider<Map<ProviderType, CloudProvider>>((ref) {
  return {
    ProviderType.google: GoogleDriveProvider(),
    ProviderType.onedrive: OneDriveProvider(),
    ProviderType.dropbox: DropboxProvider(),
  };
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AuthRepositoryImpl(
    providers: ref.watch(cloudProvidersProvider),
    accountsDao: db.accountsDao,
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final linkedAccountsProvider = StreamProvider<List<AccountEntity>>((ref) {
  return ref.watch(authRepositoryProvider).watchLinkedAccounts();
});

final linkAccountProvider = NotifierProvider<LinkAccountNotifier, AsyncValue<void>>(() {
  return LinkAccountNotifier();
});

class LinkAccountNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() {
    return const AsyncData(null);
  }

  Future<void> link(ProviderType type) async {
    state = const AsyncLoading();
    try {
      final account = await ref.read(authRepositoryProvider).linkAccount(type);
      state = const AsyncData(null);
      // Auto-sync after linking
      ref.read(syncNotifierProvider.notifier).syncAccount(account.id);
    } catch (e, st) {
      AppLogger.error('Failed to link account', error: e);
      state = AsyncError(e, st);
    }
  }

  Future<void> unlink(String accountId) async {
    state = const AsyncLoading();
    try {
      await ref.read(authRepositoryProvider).unlinkAccount(accountId);
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}
