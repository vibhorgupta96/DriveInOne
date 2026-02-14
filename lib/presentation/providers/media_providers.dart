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

final mediaItemProvider = FutureProvider.family<MediaItemEntity?, String>((ref, id) {
  return ref.watch(mediaRepositoryProvider).getMediaItemById(id);
});

final mediaCountProvider = FutureProvider<int>((ref) {
  return ref.watch(mediaRepositoryProvider).getMediaCount();
});

final searchResultsProvider = FutureProvider.family<List<MediaItemEntity>, String>((ref, query) {
  if (query.isEmpty) return Future.value([]);
  return ref.watch(mediaRepositoryProvider).searchByFileName(query);
});

final timelineNotifierProvider = StateNotifierProvider<TimelineNotifier, AsyncValue<List<MediaItemEntity>>>((ref) {
  return TimelineNotifier(ref);
});

class TimelineNotifier extends StateNotifier<AsyncValue<List<MediaItemEntity>>> {
  final Ref _ref;
  int _offset = 0;
  static const _pageSize = 50;
  bool _hasMore = true;

  TimelineNotifier(this._ref) : super(const AsyncLoading()) {
    _loadInitial();
  }

  bool get hasMore => _hasMore;

  Future<void> _loadInitial() async {
    try {
      _offset = 0;
      final items = await _ref.read(mediaRepositoryProvider)
          .getTimeline(limit: _pageSize, offset: 0);
      _hasMore = items.length == _pageSize;
      state = AsyncData(items);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> loadMore() async {
    if (!_hasMore) return;
    final currentItems = state.value ?? [];
    _offset += _pageSize;
    try {
      final newItems = await _ref.read(mediaRepositoryProvider)
          .getTimeline(limit: _pageSize, offset: _offset);
      _hasMore = newItems.length == _pageSize;
      state = AsyncData([...currentItems, ...newItems]);
    } catch (e) {
      // Keep existing items on error
      _offset -= _pageSize;
    }
  }

  Future<void> refresh() async {
    await _loadInitial();
  }
}
