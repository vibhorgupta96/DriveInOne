import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drive_in_one/core/enums/media_type.dart';
import 'package:drive_in_one/core/enums/provider_type.dart';
import 'package:drive_in_one/data/database/app_database.dart';
import 'package:drive_in_one/data/database/tables/accounts_table.dart';
import 'package:drive_in_one/data/database/tables/media_items_table.dart';
import 'package:drive_in_one/data/datasources/cloud/cloud_provider.dart';
import 'package:drive_in_one/data/datasources/cloud/dropbox_provider.dart';
import 'package:drive_in_one/data/datasources/local/secure_storage_source.dart';
import 'package:drive_in_one/data/models/media_item_model.dart';
import 'package:drive_in_one/data/models/sync_result_model.dart';
import 'package:drive_in_one/data/repositories/auth_repository_impl.dart';
import 'package:drive_in_one/data/repositories/sync_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

const _accountId = 'dropbox|sync-test@example.test';

MediaItemModel _media(String id, String path) => MediaItemModel(
  remoteId: id,
  remotePath: path,
  fileName: path.split('/').last,
  mimeType: 'image/jpeg',
  mediaType: MediaType.photo,
  timestamp: DateTime.utc(2026),
);

void main() {
  test(
    'folder tombstone then child restore leaves only the restored child',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _seed(db);
      await _insert(db, 'one', '/album/one.jpg');
      await _insert(db, 'two', '/album/two.jpg');

      final restored = _media('one', '/album/one.jpg');
      final repo = _repo(
        db,
        SyncResultModel(
          changedItems: [restored],
          deletedRemoteIds: [DropboxProvider.deletionKeyForPath('/album')],
          orderedEvents: [
            SyncDeltaEvent.deleted(
              DropboxProvider.deletionKeyForPath('/album'),
            ),
            SyncDeltaEvent.changed(restored),
          ],
        ),
      );
      addTearDown(repo.dispose);

      final result = await repo.syncAccount(_accountId);
      expect(result.itemsSynced, 1);
      // The folder tombstone removes two rows, but the ordered child restore
      // leaves one active; only the final descendant deletion is reported.
      expect(result.itemsDeleted, 1);
      expect(result.accountOutcomes.single.itemsDeleted, 1);
      expect(
        (await db.mediaItemsDao.getMediaByAccount(
          _accountId,
        )).map((item) => item.remoteId),
        ['one'],
      );
    },
  );

  test('a complete snapshot reconciles stale rows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    await _insert(db, 'stale', '/stale.jpg');
    final fresh = _media('fresh', '/fresh.jpg');
    final repo = _repo(
      db,
      SyncResultModel(
        changedItems: [fresh],
        deletedRemoteIds: const [],
        orderedEvents: [SyncDeltaEvent.changed(fresh)],
        isFullSnapshot: true,
      ),
    );
    addTearDown(repo.dispose);

    final result = await repo.syncAccount(_accountId);
    expect(result.itemsSynced, 1);
    expect(result.itemsDeleted, 1);
    expect(result.accountOutcomes.single.itemsDeleted, 1);
    expect(
      (await db.mediaItemsDao.getMediaByAccount(
        _accountId,
      )).map((item) => item.remoteId),
      ['fresh'],
    );
  });

  test('a failed scan preserves local rows and its previous cursor', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    await db.accountsDao.updateSyncToken(_accountId, 'known-cursor');
    await _insert(db, 'existing', '/existing.jpg');
    final repo = _repoFailure(
      db,
      Future<SyncResultModel>(() => throw StateError('page fetch failed')),
    );
    addTearDown(repo.dispose);

    await expectLater(repo.syncAccount(_accountId), throwsStateError);
    expect(
      (await db.mediaItemsDao.getMediaByAccount(
        _accountId,
      )).map((item) => item.remoteId),
      ['existing'],
    );
    expect(
      (await db.accountsDao.getAccountById(_accountId))!.syncToken,
      'known-cursor',
    );
  });

  test('duplicate ordered events report only each final record once', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    await _insert(db, 'restored', '/restored.jpg');
    final restored = _media('restored', '/restored.jpg');
    final repo = _repo(
      db,
      SyncResultModel(
        changedItems: [restored, restored],
        deletedRemoteIds: const ['restored'],
        orderedEvents: [
          const SyncDeltaEvent.deleted('restored'),
          SyncDeltaEvent.changed(restored),
          SyncDeltaEvent.changed(restored),
        ],
      ),
    );
    addTearDown(repo.dispose);

    final result = await repo.syncAccount(_accountId);

    expect(result.itemsSynced, 1);
    expect(result.itemsDeleted, 0);
    expect(result.accountOutcomes.single.itemsSynced, 1);
    expect(result.accountOutcomes.single.itemsDeleted, 0);
  });

  test('old sync cannot populate an account after unlink and relink', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    final pending = Completer<SyncResultModel>();
    final provider = _FixtureProvider(pending.future);
    final tokens = _Tokens();
    final repo = SyncRepositoryImpl(
      providerFactories: {
        ProviderType.dropbox: ({String? accountId}) => provider,
      },
      accountsDao: db.accountsDao,
      mediaItemsDao: db.mediaItemsDao,
      secureStorage: tokens,
    );
    addTearDown(repo.dispose);
    final statuses = <bool>[];
    final subscription = repo.watchSyncStatus().listen(
      (status) => statuses.add(status.isSyncing),
    );
    addTearDown(subscription.cancel);
    final sync = repo.syncAccount(_accountId);
    await provider.started.future;
    final auth = AuthRepositoryImpl(
      providerFactories: {
        ProviderType.dropbox: ({String? accountId}) => _FixtureProvider(
          Future.value(
            const SyncResultModel(changedItems: [], deletedRemoteIds: []),
          ),
        ),
      },
      db: db,
      accountsDao: db.accountsDao,
      secureStorage: tokens,
    );
    await auth.unlinkAccount(_accountId);
    await _seed(db);
    pending.complete(
      SyncResultModel(
        changedItems: [_media('late', '/late.jpg')],
        deletedRemoteIds: const [],
      ),
    );
    await sync;
    await Future<void>.delayed(Duration.zero);
    expect(statuses, isNotEmpty);
    expect(statuses.last, isFalse);
    expect(await db.mediaItemsDao.getMediaCount(), 0);
  });
}

Future<void> _seed(AppDatabase db) => db.accountsDao.insertAccount(
  AccountsCompanion.insert(
    id: _accountId,
    providerType: ProviderTypeEnum.dropbox,
    email: 'sync-test@example.test',
  ),
);

Future<void> _insert(AppDatabase db, String id, String path) =>
    db.mediaItemsDao.upsertMediaItem(
      MediaItemsCompanion.insert(
        id: id,
        accountId: _accountId,
        remoteId: id,
        remotePath: Value(path),
        fileName: path.split('/').last,
        mimeType: 'image/jpeg',
        mediaType: MediaTypeEnum.photo,
        timestamp: DateTime.utc(2026),
      ),
    );

SyncRepositoryImpl _repo(AppDatabase db, SyncResultModel result) =>
    SyncRepositoryImpl(
      providerFactories: {
        ProviderType.dropbox: ({String? accountId}) =>
            _FixtureProvider(Future.value(result)),
      },
      accountsDao: db.accountsDao,
      mediaItemsDao: db.mediaItemsDao,
      secureStorage: _Tokens(),
    );

SyncRepositoryImpl _repoFailure(
  AppDatabase db,
  Future<SyncResultModel> result,
) => SyncRepositoryImpl(
  providerFactories: {
    ProviderType.dropbox: ({String? accountId}) => _FixtureProvider(result),
  },
  accountsDao: db.accountsDao,
  mediaItemsDao: db.mediaItemsDao,
  secureStorage: _Tokens(),
);

class _Tokens extends SecureStorageSource {
  @override
  Future<String?> getAccessToken(String accountId) async => 'token';
  @override
  Future<String?> getRefreshToken(String accountId) async => null;
  @override
  Future<DateTime?> getTokenExpiry(String accountId) async =>
      DateTime.utc(2030);
  @override
  Future<void> deleteTokens(String accountId) async {}
  @override
  Future<void> saveTokens({
    required String accountId,
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) async {}
}

class _FixtureProvider extends CloudProvider {
  _FixtureProvider(this.result);
  final Future<SyncResultModel> result;
  final started = Completer<void>();
  @override
  String get providerId => 'dropbox';
  @override
  ProviderType get providerType => ProviderType.dropbox;
  @override
  Future<void> logout() async {}
  @override
  Future<void> refreshTokenIfNeeded({bool force = false}) async {}
  @override
  Future<SyncResultModel> scanDelta(String? syncToken) {
    if (!started.isCompleted) started.complete();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
