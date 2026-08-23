import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/media_repository_impl.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/media_repository.dart';
import 'database_providers.dart';

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return MediaRepositoryImpl(mediaItemsDao: db.mediaItemsDao);
});

final timelineProvider = StreamProvider<List<MediaItemEntity>>((ref) {
  return ref.watch(mediaRepositoryProvider).watchTimeline();
});

final mediaItemProvider =
    FutureProvider.family<MediaItemEntity?, String>((ref, id) {
  return ref.watch(mediaRepositoryProvider).getMediaItemById(id);
});

final mediaCountProvider = FutureProvider<int>((ref) {
  return ref.watch(mediaRepositoryProvider).getMediaCount();
});

final mediaStatsProvider =
    FutureProvider<Map<String, ({int photos, int videos})>>((ref) {
  return ref.watch(mediaRepositoryProvider).getMediaStatsByAccount();
});

final searchResultsProvider =
    FutureProvider.family<List<MediaItemEntity>, String>((ref, query) {
  if (query.isEmpty) return Future.value([]);
  return ref.watch(mediaRepositoryProvider).searchMedia(query, limit: 100);
});

final timelineNotifierProvider =
    NotifierProvider<TimelineNotifier, AsyncValue<List<MediaItemEntity>>>(() {
  return TimelineNotifier();
});

class TimelineNotifier extends Notifier<AsyncValue<List<MediaItemEntity>>> {
  static const _pageSize = 50;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  int _loadGeneration = 0;
  DateTime? _beforeTimestamp;
  String? _beforeId;

  @override
  AsyncValue<List<MediaItemEntity>> build() {
    _loadInitial();
    return const AsyncLoading();
  }

  bool get hasMore => _hasMore;
  bool get isLoadingMore => _isLoadingMore;

  Future<void> _loadInitial() async {
    final generation = ++_loadGeneration;
    _isLoadingMore = false;
    _beforeTimestamp = null;
    _beforeId = null;
    try {
      final items = await ref
          .read(mediaRepositoryProvider)
          .getTimelineAfter(limit: _pageSize);
      if (generation != _loadGeneration) return;
      _hasMore = items.length == _pageSize;
      _setCursor(items);
      state = AsyncData(items);
    } catch (e, st) {
      if (generation != _loadGeneration) return;
      state = AsyncError(e, st);
    }
  }

  Future<void> loadMore() async {
    if (!_hasMore || _isLoadingMore || state.isLoading) return;
    _isLoadingMore = true;
    final generation = _loadGeneration;
    final currentItems = state.value ?? [];
    try {
      final newItems = await ref.read(mediaRepositoryProvider).getTimelineAfter(
            limit: _pageSize,
            beforeTimestamp: _beforeTimestamp,
            beforeId: _beforeId,
          );
      if (generation != _loadGeneration) return;
      _hasMore = newItems.length == _pageSize;
      _setCursor(newItems);

      final seenIds = currentItems.map((item) => item.id).toSet();
      final uniqueNewItems =
          newItems.where((item) => seenIds.add(item.id)).toList();
      state = AsyncData([...currentItems, ...uniqueNewItems]);
    } catch (_) {
      // Retain the current page and cursor so the next scroll can retry.
    } finally {
      if (generation == _loadGeneration) {
        _isLoadingMore = false;
      }
    }
  }

  void _setCursor(List<MediaItemEntity> items) {
    if (items.isEmpty) return;
    final last = items.last;
    _beforeTimestamp = last.timestamp;
    _beforeId = last.id;
  }

  Future<void> refresh() async {
    await _loadInitial();
  }
}
