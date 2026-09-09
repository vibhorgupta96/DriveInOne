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

final mediaItemProvider = FutureProvider.family<MediaItemEntity?, String>((
  ref,
  id,
) {
  return ref.watch(mediaRepositoryProvider).getMediaItemById(id);
});

final mediaCountProvider = FutureProvider<int>((ref) {
  return ref.watch(mediaRepositoryProvider).getMediaCount();
});

final mediaStatsProvider =
    FutureProvider<Map<String, ({int photos, int videos})>>((ref) {
      return ref.watch(mediaRepositoryProvider).getMediaStatsByAccount();
    });

final searchResultsProvider = NotifierProvider.autoDispose
    .family<SearchResultsNotifier, AsyncValue<SearchResultsState>, String>(
      SearchResultsNotifier.new,
    );

class SearchResultsState {
  const SearchResultsState({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.loadMoreStackTrace,
  });

  final List<MediaItemEntity> items;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;
  final StackTrace? loadMoreStackTrace;

  SearchResultsState copyWith({
    List<MediaItemEntity>? items,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    StackTrace? loadMoreStackTrace,
    bool clearLoadMoreError = false,
  }) {
    return SearchResultsState(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : loadMoreError ?? this.loadMoreError,
      loadMoreStackTrace: clearLoadMoreError
          ? null
          : loadMoreStackTrace ?? this.loadMoreStackTrace,
    );
  }
}

class SearchResultsNotifier extends Notifier<AsyncValue<SearchResultsState>> {
  SearchResultsNotifier(this._query);

  static const _pageSize = 100;

  final String _query;
  int _loadGeneration = 0;

  @override
  AsyncValue<SearchResultsState> build() {
    if (_query.trim().isEmpty) {
      return const AsyncData(SearchResultsState(items: [], hasMore: false));
    }
    _loadInitial();
    return const AsyncLoading();
  }

  Future<void> _loadInitial() async {
    final generation = ++_loadGeneration;
    final query = _query.trim();
    if (query.isEmpty) {
      state = const AsyncData(SearchResultsState(items: [], hasMore: false));
      return;
    }

    try {
      final items = await ref
          .read(mediaRepositoryProvider)
          .searchMedia(query, limit: _pageSize, offset: 0);
      if (!ref.mounted || generation != _loadGeneration) return;
      state = AsyncData(
        SearchResultsState(items: items, hasMore: items.length == _pageSize),
      );
    } catch (error, stackTrace) {
      if (!ref.mounted || generation != _loadGeneration) return;
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> refresh() {
    if (_query.trim().isEmpty) {
      state = const AsyncData(SearchResultsState(items: [], hasMore: false));
      return Future.value();
    }
    state = const AsyncLoading();
    return _loadInitial();
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        !current.hasMore ||
        current.isLoadingMore ||
        state.isLoading) {
      return;
    }

    final generation = _loadGeneration;
    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    try {
      final newItems = await ref
          .read(mediaRepositoryProvider)
          .searchMedia(
            _query.trim(),
            limit: _pageSize,
            offset: current.items.length,
          );
      if (!ref.mounted || generation != _loadGeneration) return;
      state = AsyncData(
        SearchResultsState(
          items: [...current.items, ...newItems],
          hasMore: newItems.length == _pageSize,
        ),
      );
    } catch (error, stackTrace) {
      if (!ref.mounted || generation != _loadGeneration) return;
      state = AsyncData(
        current.copyWith(
          isLoadingMore: false,
          loadMoreError: error,
          loadMoreStackTrace: stackTrace,
        ),
      );
    }
  }
}

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
      final newItems = await ref
          .read(mediaRepositoryProvider)
          .getTimelineAfter(
            limit: _pageSize,
            beforeTimestamp: _beforeTimestamp,
            beforeId: _beforeId,
          );
      if (generation != _loadGeneration) return;
      _hasMore = newItems.length == _pageSize;
      _setCursor(newItems);

      final seenIds = currentItems.map((item) => item.id).toSet();
      final uniqueNewItems = newItems
          .where((item) => seenIds.add(item.id))
          .toList();
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
