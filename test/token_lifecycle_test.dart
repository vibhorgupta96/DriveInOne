import 'dart:async';

import 'package:drift/native.dart';
import 'package:drive_in_one/core/enums/provider_type.dart';
import 'package:drive_in_one/data/database/app_database.dart';
import 'package:drive_in_one/data/database/tables/accounts_table.dart';
import 'package:drive_in_one/data/datasources/cloud/cloud_provider.dart';
import 'package:drive_in_one/data/datasources/local/secure_storage_source.dart';
import 'package:drive_in_one/data/models/account_model.dart';
import 'package:drive_in_one/data/models/sync_result_model.dart';
import 'package:drive_in_one/data/repositories/auth_repository_impl.dart';
import 'package:drive_in_one/data/repositories/sync_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

const _accountId = 'dropbox|token-lifecycle@example.test';

void main() {
  test(
    'unlink serializes against an in-progress secure-storage write',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _seedAccount(db);
      final tokens = _DeferredWriteTokens();
      final sync = _syncRepository(db, _FixtureProvider(), tokens);
      addTearDown(sync.dispose);

      final pendingSync = sync.syncAccount(_accountId);
      await tokens.writeStarted.future;
      final auth = _authRepository(db, tokens);
      final unlink = auth.unlinkAccount(_accountId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      tokens.finishWrite.complete();
      await pendingSync;
      await unlink;

      expect(tokens.token, isNull);
    },
  );

  test(
    'refresh started before unlink cannot restore retired credentials',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _seedAccount(db);
      final tokens = _MemoryTokens();
      final provider = _DeferredRefreshProvider();
      final sync = _syncRepository(db, provider, tokens);
      addTearDown(sync.dispose);

      final pendingSync = sync.syncAccount(_accountId);
      await provider.refreshStarted.future;
      await _authRepository(db, tokens).unlinkAccount(_accountId);
      await _seedAccount(db);
      tokens.token = 'new-session-token';
      provider.finishRefresh.complete();
      await pendingSync;

      expect(tokens.token, 'new-session-token');
    },
  );

  test(
    'a direct reconnect retires an older refresh before saving new tokens',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _seedAccount(db);
      final tokens = _MemoryTokens();
      final staleProvider = _DeferredRefreshProvider();
      final sync = _syncRepository(db, staleProvider, tokens);
      addTearDown(sync.dispose);
      final pendingSync = sync.syncAccount(_accountId);
      await staleProvider.refreshStarted.future;

      final auth = AuthRepositoryImpl(
        providerFactories: {
          ProviderType.dropbox: ({String? accountId}) =>
              accountId == null ? _LoginProvider() : _FixtureProvider(),
        },
        db: db,
        accountsDao: db.accountsDao,
        secureStorage: tokens,
      );
      await auth.linkAccount(ProviderType.dropbox);
      staleProvider.finishRefresh.complete();
      await pendingSync;

      expect(tokens.token, 'fresh-reconnect-token');
    },
  );
}

Future<void> _seedAccount(AppDatabase db) => db.accountsDao.insertAccount(
  AccountsCompanion.insert(
    id: _accountId,
    providerType: ProviderTypeEnum.dropbox,
    email: 'token-lifecycle@example.test',
  ),
);

SyncRepositoryImpl _syncRepository(
  AppDatabase db,
  CloudProvider provider,
  _MemoryTokens tokens,
) => SyncRepositoryImpl(
  providerFactories: {ProviderType.dropbox: ({String? accountId}) => provider},
  accountsDao: db.accountsDao,
  mediaItemsDao: db.mediaItemsDao,
  secureStorage: tokens,
);

AuthRepositoryImpl _authRepository(AppDatabase db, _MemoryTokens tokens) =>
    AuthRepositoryImpl(
      providerFactories: {
        ProviderType.dropbox: ({String? accountId}) => _FixtureProvider(),
      },
      db: db,
      accountsDao: db.accountsDao,
      secureStorage: tokens,
    );

class _MemoryTokens extends SecureStorageSource {
  String? token = 'fixture-token';

  @override
  Future<String?> getAccessToken(String accountId) async => token;

  @override
  Future<String?> getRefreshToken(String accountId) async => null;

  @override
  Future<DateTime?> getTokenExpiry(String accountId) async =>
      DateTime.utc(2030);

  @override
  Future<void> saveTokens({
    required String accountId,
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) async {
    token = accessToken;
  }

  @override
  Future<void> deleteTokens(String accountId) async {
    token = null;
  }
}

class _DeferredWriteTokens extends _MemoryTokens {
  final writeStarted = Completer<void>();
  final finishWrite = Completer<void>();

  @override
  Future<void> saveTokens({
    required String accountId,
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await finishWrite.future;
    token = accessToken;
  }
}

class _FixtureProvider extends CloudProvider {
  @override
  String get providerId => 'dropbox';

  @override
  ProviderType get providerType => ProviderType.dropbox;

  @override
  Future<void> refreshTokenIfNeeded({bool force = false}) async {}

  @override
  Future<void> logout() async => clearTokens();

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async =>
      const SyncResultModel(changedItems: [], deletedRemoteIds: []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredRefreshProvider extends _FixtureProvider {
  final refreshStarted = Completer<void>();
  final finishRefresh = Completer<void>();

  @override
  Future<void> refreshTokenIfNeeded({bool force = false}) async {
    refreshStarted.complete();
    await finishRefresh.future;
    setTokens(accessToken: 'retired-session-refreshed-token');
  }
}

class _LoginProvider extends _FixtureProvider {
  @override
  Future<AccountModel> login() async => AccountModel(
    id: _accountId,
    providerType: ProviderType.dropbox,
    email: 'token-lifecycle@example.test',
    accessToken: 'fresh-reconnect-token',
    tokenExpiry: DateTime.utc(2030),
  );
}
