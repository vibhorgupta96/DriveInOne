import '../../core/enums/provider_type.dart';
import '../../core/errors/exceptions.dart';
import '../../domain/entities/account.dart';
import '../../domain/repositories/auth_repository.dart';
import '../database/daos/accounts_dao.dart';
import '../database/tables/accounts_table.dart';
import '../datasources/cloud/cloud_provider.dart';
import '../datasources/local/secure_storage_source.dart';
import 'package:drift/drift.dart';

class AuthRepositoryImpl implements AuthRepository {
  final Map<ProviderType, CloudProvider> providers;
  final AccountsDao accountsDao;
  final SecureStorageSource secureStorage;

  AuthRepositoryImpl({
    required this.providers,
    required this.accountsDao,
    required this.secureStorage,
  });

  CloudProvider _getProvider(ProviderType type) {
    final provider = providers[type];
    if (provider == null) {
      throw AuthException(message: 'No provider found for $type');
    }
    return provider;
  }

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
  Future<AccountEntity> linkAccount(ProviderType type) async {
    final provider = _getProvider(type);
    final accountModel = await provider.login();

    // Store tokens securely
    await secureStorage.saveTokens(
      accountId: accountModel.id,
      accessToken: accountModel.accessToken,
      refreshToken: accountModel.refreshToken,
      expiry: accountModel.tokenExpiry,
    );

    // Save account metadata to database
    await accountsDao.insertAccount(AccountsCompanion(
      id: Value(accountModel.id),
      providerType: Value(_providerTypeToEnum(type)),
      email: Value(accountModel.email),
      displayName: Value(accountModel.displayName),
      avatarUrl: Value(accountModel.avatarUrl),
      tokenExpiry: Value(accountModel.tokenExpiry),
    ));

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

    final providerType = _enumToProviderType(account.providerType);
    final provider = _getProvider(providerType);

    // Restore provider tokens for logout
    await _restoreProviderTokens(accountId, provider);

    await provider.logout();
    await secureStorage.deleteTokens(accountId);
    await accountsDao.deleteAccount(accountId);
  }

  @override
  Future<List<AccountEntity>> getLinkedAccounts() async {
    final accounts = await accountsDao.getAllAccounts();
    return accounts.map(_mapToEntity).toList();
  }

  @override
  Stream<List<AccountEntity>> watchLinkedAccounts() {
    return accountsDao.watchAllAccounts().map(
      (accounts) => accounts.map(_mapToEntity).toList(),
    );
  }

  @override
  Future<Map<String, String>> getAuthHeaders(String accountId) async {
    final account = await accountsDao.getAccountById(accountId);
    if (account == null) {
      throw const AuthException(message: 'Account not found');
    }

    final providerType = _enumToProviderType(account.providerType);
    final provider = _getProvider(providerType);
    await _restoreProviderTokens(accountId, provider);
    return provider.getAuthHeaders();
  }

  @override
  Future<void> refreshToken(String accountId) async {
    final account = await accountsDao.getAccountById(accountId);
    if (account == null) return;

    final providerType = _enumToProviderType(account.providerType);
    final provider = _getProvider(providerType);
    await _restoreProviderTokens(accountId, provider);
    await provider.refreshTokenIfNeeded();

    // Save updated tokens
    if (provider.accessToken != null) {
      await secureStorage.saveTokens(
        accountId: accountId,
        accessToken: provider.accessToken!,
      );
    }
  }

  Future<void> _restoreProviderTokens(String accountId, CloudProvider provider) async {
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
  }

  AccountEntity _mapToEntity(Account account) {
    return AccountEntity(
      id: account.id,
      providerType: _enumToProviderType(account.providerType),
      email: account.email,
      displayName: account.displayName,
      avatarUrl: account.avatarUrl,
      syncToken: account.syncToken,
      tokenExpiry: account.tokenExpiry,
      createdAt: account.createdAt,
    );
  }
}
