import '../entities/media_item.dart';

abstract class MediaRepository {
  Future<List<MediaItemEntity>> getTimeline({required int limit, required int offset});
  Stream<List<MediaItemEntity>> watchTimeline();
  Future<List<MediaItemEntity>> getMediaByDateRange(DateTime start, DateTime end);
  Future<List<MediaItemEntity>> getMediaByAccount(String accountId);
  Future<List<MediaItemEntity>> searchByFileName(String query);
  Future<MediaItemEntity?> getMediaItemById(String id);
  Future<int> getMediaCount();
  Future<Map<String, ({int photos, int videos})>> getMediaStatsByAccount();
  Future<List<MediaItemEntity>> getMediaItemsByIds(List<String> ids);
}
