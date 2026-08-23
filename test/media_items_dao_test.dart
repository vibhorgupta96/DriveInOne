import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drive_in_one/data/database/app_database.dart';
import 'package:drive_in_one/data/database/tables/accounts_table.dart';
import 'package:drive_in_one/data/database/tables/media_items_table.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.accountsDao.insertAccount(AccountsCompanion.insert(
      id: 'dropbox-account',
      providerType: ProviderTypeEnum.dropbox,
      email: 'photos@example.com',
      displayName: const Value('Holiday Archive'),
    ));
  });

  tearDown(() => db.close());

  MediaItemsCompanion media({
    required String id,
    String accountId = 'dropbox-account',
    String? remoteId,
    String fileName = 'sunset.jpg',
    String mimeType = 'image/jpeg',
    String remotePath = '/camera/sunset.jpg',
    String hash = 'hash-a',
    int size = 100,
    DateTime? timestamp,
    bool facesProcessed = false,
  }) {
    return MediaItemsCompanion.insert(
      id: id,
      accountId: accountId,
      remoteId: remoteId ?? 'remote-$id',
      remotePath: Value(remotePath),
      fileName: fileName,
      mimeType: mimeType,
      mediaType: MediaTypeEnum.photo,
      fileHash: Value(hash),
      fileSize: Value(size),
      timestamp: timestamp ?? DateTime.utc(2026, 1, 1),
      facesProcessed: Value(facesProcessed),
    );
  }

  test('metadata-only upserts preserve face processing state', () async {
    await db.mediaItemsDao.upsertMediaItem(
      media(id: 'one', facesProcessed: true),
    );

    await db.mediaItemsDao.upsertMediaItem(
      media(id: 'one', fileName: 'renamed.jpg'),
    );
    expect((await db.mediaItemsDao.getMediaItemById('one'))!.facesProcessed,
        isTrue);

    await db.mediaItemsDao.upsertMediaItem(
      media(id: 'one', fileName: 'renamed.jpg', hash: 'hash-b'),
    );
    expect((await db.mediaItemsDao.getMediaItemById('one'))!.facesProcessed,
        isFalse);
  });

  test('search covers metadata, provider, and account while hiding deletes',
      () async {
    await db.mediaItemsDao.batchUpsert([
      media(id: 'one'),
      media(
        id: 'two',
        fileName: 'clip.mov',
        mimeType: 'video/quicktime',
        remotePath: '/private/clip.mov',
      ),
    ]);

    expect(await db.mediaItemsDao.searchMedia('quicktime'), hasLength(1));
    expect(await db.mediaItemsDao.searchMedia('camera'), hasLength(1));
    expect(await db.mediaItemsDao.searchMedia('Holiday Archive'), hasLength(2));
    expect(await db.mediaItemsDao.searchMedia('dropbox'), hasLength(2));
    expect(
        await db.mediaItemsDao.searchMedia('photos@example.com'), hasLength(2));

    await db.mediaItemsDao.markDeleted('dropbox-account', 'remote-one');
    expect(await db.mediaItemsDao.searchMedia('sunset'), isEmpty);
    expect(await db.mediaItemsDao.getMediaItemsByIds(['one', 'two']),
        hasLength(1));
  });

  test('path deletion keys match Dropbox paths', () async {
    await db.mediaItemsDao.upsertMediaItem(media(id: 'one'));
    await db.facesDao.insertCluster(FaceClustersCompanion.insert(
      id: 'deleted-cluster',
      representativeFaceId: const Value('deleted-face'),
      faceCount: const Value(1),
    ));
    await db.facesDao.insertFace(FacesCompanion.insert(
      id: 'deleted-face',
      mediaItemId: 'one',
      boundingBox: '{}',
      embedding: _embedding(1),
      clusterId: const Value('deleted-cluster'),
    ));

    await db.mediaItemsDao.batchMarkDeleted(
      'dropbox-account',
      ['path:/camera/sunset.jpg'],
    );

    expect((await db.mediaItemsDao.getMediaItemById('one'))!.isDeleted, isTrue);
    expect(await db.facesDao.getFaceById('deleted-face'), isNull);
    expect(await db.facesDao.getClusterById('deleted-cluster'), isNull);

    await db.mediaItemsDao.upsertMediaItem(
      media(id: 'one', facesProcessed: true),
    );
    final restored = await db.mediaItemsDao.getMediaItemById('one');
    expect(restored!.isDeleted, isFalse);
    expect(restored.facesProcessed, isFalse);
  });

  test('timeline cursor is stable for equal timestamps', () async {
    final timestamp = DateTime.utc(2026, 1, 1);
    await db.mediaItemsDao.batchUpsert([
      media(id: 'a', timestamp: timestamp),
      media(id: 'b', timestamp: timestamp),
      media(id: 'c', timestamp: timestamp),
    ]);

    final firstPage = await db.mediaItemsDao.getTimelinePageAfter(limit: 2);
    final secondPage = await db.mediaItemsDao.getTimelinePageAfter(
      limit: 2,
      beforeTimestamp: firstPage.last.timestamp,
      beforeId: firstPage.last.id,
    );

    expect(firstPage.map((item) => item.id), ['c', 'b']);
    expect(secondPage.map((item) => item.id), ['a']);
  });

  test('account purge recomputes shared face clusters', () async {
    await db.accountsDao.insertAccount(AccountsCompanion.insert(
      id: 'google-account',
      providerType: ProviderTypeEnum.google,
      email: 'other@example.com',
    ));
    await db.mediaItemsDao.batchUpsert([
      media(id: 'one'),
      media(id: 'two', accountId: 'google-account'),
    ]);
    await db.into(db.faceClusters).insert(FaceClustersCompanion.insert(
          id: 'cluster',
          representativeFaceId: const Value('face-one'),
          centroidEmbedding: Value(_embedding(2)),
          faceCount: const Value(2),
        ));
    await db.into(db.faces).insert(FacesCompanion.insert(
          id: 'face-one',
          mediaItemId: 'one',
          boundingBox: '{}',
          embedding: _embedding(1),
          clusterId: const Value('cluster'),
        ));
    await db.into(db.faces).insert(FacesCompanion.insert(
          id: 'face-two',
          mediaItemId: 'two',
          boundingBox: '{}',
          embedding: _embedding(3),
          clusterId: const Value('cluster'),
        ));

    await db.deleteAccountData('dropbox-account');

    expect(await db.accountsDao.getAccountById('dropbox-account'), isNull);
    expect(await db.mediaItemsDao.getMediaItemById('one'), isNull);
    expect(await db.facesDao.getFaceById('face-one'), isNull);
    final cluster = await db.facesDao.getClusterById('cluster');
    expect(cluster, isNotNull);
    expect(cluster!.faceCount, 1);
    expect(cluster.representativeFaceId, 'face-two');
    expect(_firstFloat(cluster.centroidEmbedding!), closeTo(3, 0.0001));
  });
}

Uint8List _embedding(double value) =>
    Float32List.fromList([value, value]).buffer.asUint8List();

double _firstFloat(Uint8List bytes) =>
    ByteData.sublistView(bytes).getFloat32(0, Endian.host);
