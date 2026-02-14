import '../../core/enums/media_type.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/media_repository.dart';
import '../database/daos/media_items_dao.dart';
import '../database/app_database.dart';
import '../database/tables/media_items_table.dart';

class MediaRepositoryImpl implements MediaRepository {
  final MediaItemsDao mediaItemsDao;

  MediaRepositoryImpl({required this.mediaItemsDao});

  MediaItemEntity _mapToEntity(MediaItem item) {
    return MediaItemEntity(
      id: item.id,
      accountId: item.accountId,
      remoteId: item.remoteId,
      remotePath: item.remotePath,
      fileName: item.fileName,
      mimeType: item.mimeType,
      mediaType: item.mediaType == MediaTypeEnum.photo ? MediaType.photo : MediaType.video,
      thumbnailUrl: item.thumbnailUrl,
      fullSizeUrl: item.fullSizeUrl,
      width: item.width,
      height: item.height,
      fileSize: item.fileSize,
      durationSeconds: item.durationSeconds,
      fileHash: item.fileHash,
      timestamp: item.timestamp,
      syncedAt: item.syncedAt,
      facesProcessed: item.facesProcessed,
    );
  }

  @override
  Future<List<MediaItemEntity>> getTimeline({required int limit, required int offset}) async {
    final items = await mediaItemsDao.getTimelinePage(limit, offset);
    return items.map(_mapToEntity).toList();
  }

  @override
  Stream<List<MediaItemEntity>> watchTimeline() {
    return mediaItemsDao.watchTimeline().map(
      (items) => items.map(_mapToEntity).toList(),
    );
  }

  @override
  Future<List<MediaItemEntity>> getMediaByDateRange(DateTime start, DateTime end) async {
    final items = await mediaItemsDao.getMediaByDateRange(start, end);
    return items.map(_mapToEntity).toList();
  }

  @override
  Future<List<MediaItemEntity>> getMediaByAccount(String accountId) async {
    final items = await mediaItemsDao.getMediaByAccount(accountId);
    return items.map(_mapToEntity).toList();
  }

  @override
  Future<List<MediaItemEntity>> searchByFileName(String query) async {
    final items = await mediaItemsDao.searchByFileName(query);
    return items.map(_mapToEntity).toList();
  }

  @override
  Future<MediaItemEntity?> getMediaItemById(String id) async {
    final item = await mediaItemsDao.getMediaItemById(id);
    if (item == null) return null;
    return _mapToEntity(item);
  }

  @override
  Future<int> getMediaCount() => mediaItemsDao.getMediaCount();

  @override
  Future<List<MediaItemEntity>> getMediaItemsByIds(List<String> ids) async {
    final items = await mediaItemsDao.getMediaItemsByIds(ids);
    return items.map(_mapToEntity).toList();
  }
}
