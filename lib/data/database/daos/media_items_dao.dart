import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/media_items_table.dart';

part 'media_items_dao.g.dart';

@DriftAccessor(tables: [MediaItems])
class MediaItemsDao extends DatabaseAccessor<AppDatabase>
    with _$MediaItemsDaoMixin {
  MediaItemsDao(super.db);

  Future<List<MediaItem>> getTimelinePage(int limit, int offset) =>
      (select(mediaItems)
            ..where((m) => m.isDeleted.equals(false))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)])
            ..limit(limit, offset: offset))
          .get();

  Stream<List<MediaItem>> watchTimeline() =>
      (select(mediaItems)
            ..where((m) => m.isDeleted.equals(false))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .watch();

  Future<List<MediaItem>> getMediaByDateRange(DateTime start, DateTime end) =>
      (select(mediaItems)
            ..where((m) =>
                m.isDeleted.equals(false) &
                m.timestamp.isBiggerOrEqualValue(start) &
                m.timestamp.isSmallerOrEqualValue(end))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .get();

  Future<List<MediaItem>> getMediaByAccount(String accountId) =>
      (select(mediaItems)
            ..where(
                (m) => m.isDeleted.equals(false) & m.accountId.equals(accountId))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .get();

  Future<List<MediaItem>> searchByFileName(String query) =>
      (select(mediaItems)
            ..where((m) =>
                m.isDeleted.equals(false) & m.fileName.contains(query))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .get();

  Future<void> upsertMediaItem(MediaItemsCompanion item) =>
      into(mediaItems).insert(item, mode: InsertMode.insertOrReplace);

  Future<void> markDeleted(String accountId, String remoteId) =>
      (update(mediaItems)
            ..where(
                (m) => m.accountId.equals(accountId) & m.remoteId.equals(remoteId)))
          .write(const MediaItemsCompanion(isDeleted: Value(true)));

  Future<void> deleteByAccount(String accountId) =>
      (delete(mediaItems)..where((m) => m.accountId.equals(accountId))).go();

  Future<MediaItem?> getMediaItemById(String id) =>
      (select(mediaItems)..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<List<MediaItem>> getMediaItemsWithoutFaces(int limit) =>
      (select(mediaItems)
            ..where((m) =>
                m.isDeleted.equals(false) &
                m.facesProcessed.equals(false))
            ..limit(limit))
          .get();

  Future<void> markFacesProcessed(String id) =>
      (update(mediaItems)..where((m) => m.id.equals(id)))
          .write(const MediaItemsCompanion(facesProcessed: Value(true)));

  Future<int> getMediaCount() async {
    final count = countAll();
    final query = selectOnly(mediaItems)
      ..where(mediaItems.isDeleted.equals(false))
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<MediaItem>> getMediaItemsByIds(List<String> ids) =>
      (select(mediaItems)..where((m) => m.id.isIn(ids))).get();

  Future<int> getProcessedFacesCount() async {
    final count = countAll();
    final query = selectOnly(mediaItems)
      ..where(mediaItems.isDeleted.equals(false) & mediaItems.facesProcessed.equals(true))
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<Map<String, ({int photos, int videos})>>
      getMediaStatsByAccount() async {
    final results = await customSelect(
      'SELECT account_id, media_type, COUNT(*) as cnt '
      'FROM media_items '
      'WHERE is_deleted = 0 '
      'GROUP BY account_id, media_type',
    ).get();

    final stats = <String, ({int photos, int videos})>{};
    for (final row in results) {
      final accountId = row.read<String>('account_id');
      final mediaType = row.read<int>('media_type');
      final count = row.read<int>('cnt');
      final existing = stats[accountId] ?? (photos: 0, videos: 0);
      if (mediaType == MediaTypeEnum.photo.index) {
        stats[accountId] = (photos: count, videos: existing.videos);
      } else {
        stats[accountId] = (photos: existing.photos, videos: count);
      }
    }
    return stats;
  }

  Future<void> resetAllFacesProcessed() =>
      (update(mediaItems)..where((m) => m.facesProcessed.equals(true)))
          .write(const MediaItemsCompanion(facesProcessed: Value(false)));
}
