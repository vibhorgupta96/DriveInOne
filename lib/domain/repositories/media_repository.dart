import '../entities/media_item.dart';

abstract class MediaRepository {
  Future<List<MediaItemEntity>> getTimeline({
    required int limit,
    required int offset,
  });
  Future<List<MediaItemEntity>> getTimelineAfter({
    required int limit,
    DateTime? beforeTimestamp,
    String? beforeId,
  });
  Stream<List<MediaItemEntity>> watchTimeline();
  Future<List<MediaItemEntity>> getMediaByDateRange(
    DateTime start,
    DateTime end,
  );
  Future<List<MediaItemEntity>> getMediaByAccount(String accountId);
  Future<List<MediaItemEntity>> searchMedia(
    String query, {
    int limit = 100,
    int offset = 0,
  });
  Future<MediaItemEntity?> getMediaItemById(String id);
  Future<int> getMediaCount();
  Future<Map<String, ({int photos, int videos})>> getMediaStatsByAccount();
  Future<List<MediaItemEntity>> getMediaItemsByIds(List<String> ids);
}
