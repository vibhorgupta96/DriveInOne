import '../../core/enums/provider_type.dart';
import '../../core/extensions/enum_converters.dart';
import '../../core/errors/exceptions.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/account.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/resolved_media.dart';
import '../../domain/repositories/auth_repository.dart';
import '../database/app_database.dart';
import '../database/daos/accounts_dao.dart';
import '../datasources/cloud/cloud_provider.dart';
import '../datasources/local/secure_storage_source.dart';
import '../datasources/local/account_operation_gate.dart';
import '../datasources/local/thumbnail_resolver.dart';
import 'package:drift/drift.dart';

class AuthRepositoryImpl implements AuthRepository {
  final Map<ProviderType, CloudProviderFactory> providerFactories;
  final AppDatabase db;
  final AccountsDao accountsDao;
  final SecureStorageSource secureStorage;

  AuthRepositoryImpl({
    required this.providerFactories,
    required this.db,
    required this.accountsDao,
    required this.secureStorage,
  });

  CloudProvider _createProvider(ProviderType type, {String? accountId}) {
    final factory = providerFactories[type];
    if (factory == null) {
      throw AuthException(message: 'No provider found for $type');
    }
    return factory(accountId: accountId);
  }

  @override
  Future<AccountEntity> linkAccount(ProviderType type) async {
    final provider = _createProvider(type);
    final accountModel = await provider.login();
    // A reconnect supersedes every in-flight refresh for this identity before
    // queuing its newly issued credentials and account metadata.
    AccountOperationGate.retire(accountModel.id);
    final generation = AccountOperationGate.generationFor(accountModel.id);

    final committed = await AccountOperationGate.runIfCurrent<bool>(
      accountModel.id,
      generation,
      () async {
        await secureStorage.saveTokens(
          accountId: accountModel.id,
          accessToken: accountModel.accessToken,
          refreshToken: accountModel.refreshToken,
          expiry: accountModel.tokenExpiry,
        );
        await accountsDao.insertAccount(
          AccountsCompanion(
            id: Value(accountModel.id),
            providerType: Value(type.toDbEnum()),
            email: Value(accountModel.email),
            displayName: Value(accountModel.displayName),
            avatarUrl: Value(accountModel.avatarUrl),
            tokenExpiry: Value(accountModel.tokenExpiry),
          ),
        );
        return true;
      },
    );
    if (committed != true) {
      throw const AuthException(
        message: 'Account linking was cancelled because the account changed',
      );
    }

    return AccountEntity(
      id: accountModel.id,
      providerType: type,
      email: accountModel.email,
      displayName: accountModel.displayName,
      avatarUrl: accountModel.avatarUrl,
      tokenExpiry: accountModel.tokenExpiry,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> unlinkAccount(String accountId) async {
    final account = await accountsDao.getAccountById(accountId);
    if (account == null) return;

    final providerType = account.providerType.toDomain();
    final provider = _createProvider(providerType, accountId: accountId);
    Future<void> remoteLogout() async {
      try {
        await _restoreProviderTokens(accountId, provider);
        await provider.logout();
      } catch (error, stackTrace) {
        AppLogger.error(
          'Remote logout failed for $accountId; continuing local unlink',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Reserve local cleanup at retirement time. A new link for this account
    // queues behind it, including while remote logout is in flight.
    await AccountOperationGate.retireAndRunExclusive(accountId, () async {
      await remoteLogout();
      await secureStorage.deleteTokens(accountId);
      await db.deleteAccountData(accountId);
      await ThumbnailResolver().purgeAccount(accountId);
    });
  }

  @override
  Future<List<AccountEntity>> getLinkedAccounts() async {
    final accounts = await accountsDao.getAllAccounts();
    return accounts.map<AccountEntity>(_mapToEntity).toList();
  }

  @override
  Stream<List<AccountEntity>> watchLinkedAccounts() {
    return accountsDao.watchAllAccounts().map(
      (accounts) => accounts.map<AccountEntity>(_mapToEntity).toList(),
    );
  }

  @override
  Future<Map<String, String>> getAuthHeaders(String accountId) async {
    final account = await accountsDao.getAccountById(accountId);
    if (account == null) {
      throw const AuthException(message: 'Account not found');
    }

    final providerType = account.providerType.toDomain();
    final provider = _createProvider(providerType, accountId: accountId);
    final generation = AccountOperationGate.generationFor(accountId);
    await _restoreProviderTokens(accountId, provider);
    final headers = await provider.getAuthHeaders();
    await _persistProviderTokens(accountId, provider, generation: generation);
    return headers;
  }

  @override
  Future<ResolvedMedia> resolveMedia(MediaItemEntity mediaItem) async {
    final account = await accountsDao.getAccountById(mediaItem.accountId);
    if (account == null) {
      throw const AuthException(message: 'Account not found');
    }

    final providerType = account.providerType.toDomain();
    final provider = _createProvider(
      providerType,
      accountId: mediaItem.accountId,
    );
    final generation = AccountOperationGate.generationFor(mediaItem.accountId);
    await _restoreProviderTokens(mediaItem.accountId, provider);

    final url = await provider.getVideoStreamUrl(mediaItem.remoteId);
    final uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null || !uri.hasScheme) {
      throw AuthException(
        message: 'Could not resolve ${mediaItem.fileName} for viewing',
      );
    }

    // Google Drive media endpoints require bearer authentication. OneDrive
    // and Dropbox return short-lived signed download URLs.
    final headers = providerType == ProviderType.google
        ? await provider.getAuthHeaders()
        : const <String, String>{};
    await _persistProviderTokens(
      mediaItem.accountId,
      provider,
      generation: generation,
    );
    return ResolvedMedia(uri: uri, headers: headers);
  }

  @override
  Future<void> refreshToken(String accountId) async {
    final account = await accountsDao.getAccountById(accountId);
    if (account == null) return;

    final providerType = account.providerType.toDomain();
    final provider = _createProvider(providerType, accountId: accountId);
    final generation = AccountOperationGate.generationFor(accountId);
    await _restoreProviderTokens(accountId, provider);
    await provider.refreshTokenIfNeeded();

    await _persistProviderTokens(accountId, provider, generation: generation);
  }

  Future<void> _restoreProviderTokens(
    String accountId,
    CloudProvider provider,
  ) async {
    final accessToken = await secureStorage.getAccessToken(accountId);
    final refreshToken = await secureStorage.getRefreshToken(accountId);
    final expiry = await secureStorage.getTokenExpiry(accountId);

    if (accessToken != null) {
      provider.setTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiry: expiry,
      );
    } else {
      provider.clearTokens();
      throw const AuthException(message: 'No access token found for account');
    }
  }

  Future<void> _persistProviderTokens(
    String accountId,
    CloudProvider provider, {
    int? generation,
  }) async {
    if (generation != null &&
        !AccountOperationGate.isCurrent(accountId, generation)) {
      return;
    }
    final token = provider.accessToken;
    if (token == null) return;
    await AccountOperationGate.runIfCurrent(
      accountId,
      generation ?? AccountOperationGate.generationFor(accountId),
      () => secureStorage.saveTokens(
        accountId: accountId,
        accessToken: token,
        refreshToken: provider.refreshToken,
        expiry: provider.tokenExpiry,
      ),
    );
  }

  AccountEntity _mapToEntity(Account account) {
    return AccountEntity(
      id: account.id,
      providerType: account.providerType.toDomain(),
      email: account.email,
      displayName: account.displayName,
      avatarUrl: account.avatarUrl,
      syncToken: account.syncToken,
      tokenExpiry: account.tokenExpiry,
      createdAt: account.createdAt,
    );
  }
}
