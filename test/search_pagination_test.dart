import 'dart:async';

import 'package:drive_in_one/core/enums/media_type.dart';
import 'package:drive_in_one/domain/entities/media_item.dart';
import 'package:drive_in_one/domain/repositories/media_repository.dart';
import 'package:drive_in_one/presentation/providers/media_providers.dart';
import 'package:drive_in_one/presentation/screens/search/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchResultsNotifier', () {
    test('empty query is immediately empty instead of loading', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(searchResultsProvider(''));
      expect(state, isA<AsyncData<SearchResultsState>>());
      expect(state.requireValue.items, isEmpty);
      expect(state.requireValue.hasMore, isFalse);
    });

    test('loads every result beyond the first 100-row page', () async {
      final repository = _SearchRepository({'sunset': _items('sunset', 225)});
      final container = ProviderContainer(
        overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        searchResultsProvider('sunset'),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await container.pump();
      expect(
        container.read(searchResultsProvider('sunset')).value?.items,
        hasLength(100),
      );
      expect(
        container.read(searchResultsProvider('sunset')).value?.hasMore,
        isTrue,
      );

      await container.read(searchResultsProvider('sunset').notifier).loadMore();
      await container.read(searchResultsProvider('sunset').notifier).loadMore();

      final results = container
          .read(searchResultsProvider('sunset'))
          .requireValue;
      expect(results.items, hasLength(225));
      expect(results.hasMore, isFalse);
      expect(repository.calls.map((call) => (call.limit, call.offset)), [
        (100, 0),
        (100, 100),
        (100, 200),
      ]);
    });

    test(
      'drops a disposed query\'s stale pending page after a query change',
      () async {
        final slowPage = Completer<List<MediaItemEntity>>();
        final repository = _SearchRepository(
          {'first': _items('first', 100), 'second': _items('second', 1)},
          pendingPage: (query, offset) =>
              query == 'first' && offset == 100 ? slowPage.future : null,
        );
        final container = ProviderContainer(
          overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
        );
        addTearDown(container.dispose);

        final firstSubscription = container.listen(
          searchResultsProvider('first'),
          (_, _) {},
          fireImmediately: true,
        );
        await container.pump();
        final staleLoad = container
            .read(searchResultsProvider('first').notifier)
            .loadMore();
        await container.pump();
        expect(
          container
              .read(searchResultsProvider('first'))
              .requireValue
              .isLoadingMore,
          isTrue,
        );

        firstSubscription.close();
        await container.pump();
        final secondSubscription = container.listen(
          searchResultsProvider('second'),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(secondSubscription.close);
        await container.pump();
        expect(
          container
              .read(searchResultsProvider('second'))
              .requireValue
              .items
              .single
              .id,
          'second-0',
        );

        slowPage.complete(_items('first-stale', 100));
        await staleLoad;
        await container.pump();

        final secondResults = container
            .read(searchResultsProvider('second'))
            .requireValue;
        expect(secondResults.items.map((item) => item.id), ['second-0']);
      },
    );

    test('keeps loaded items and retries a failed later page', () async {
      var failLaterPage = true;
      final repository = _SearchRepository(
        {'retry': _items('retry', 101)},
        onSearch: (query, limit, offset) {
          if (query == 'retry' && offset == 100 && failLaterPage) {
            failLaterPage = false;
            throw StateError('temporary failure');
          }
          final matches = _items('retry', 101);
          return matches.skip(offset).take(limit).toList();
        },
      );
      final container = ProviderContainer(
        overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        searchResultsProvider('retry'),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await container.pump();
      await container.read(searchResultsProvider('retry').notifier).loadMore();
      final failedPage = container
          .read(searchResultsProvider('retry'))
          .requireValue;
      expect(failedPage.items, hasLength(100));
      expect(failedPage.loadMoreError, isA<StateError>());

      await container.read(searchResultsProvider('retry').notifier).loadMore();
      final retriedPage = container
          .read(searchResultsProvider('retry'))
          .requireValue;
      expect(retriedPage.items, hasLength(101));
      expect(retriedPage.loadMoreError, isNull);
      expect(retriedPage.hasMore, isFalse);
    });
  });

  testWidgets('search screen fetches later pages when scrolling', (
    tester,
  ) async {
    final repository = _SearchRepository({'sunset': _items('sunset', 201)});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );

    await tester.enterText(find.byType(TextField), 'sunset');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('100 results'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();
    expect(find.text('200 results'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();
    expect(find.text('201 results'), findsOneWidget);
    expect(find.text('All 201 results loaded'), findsOneWidget);
  });

  testWidgets('clearing search cancels a pending debounced query', (
    tester,
  ) async {
    final repository = _SearchRepository({
      'sunset': _items('sunset', 1),
      'moon': _items('moon', 1),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );

    await tester.enterText(find.byType(TextField), 'sunset');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1 results'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'moon');
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Search your gallery'), findsOneWidget);
    expect(find.text('No results for "moon"'), findsNothing);
  });
}

List<MediaItemEntity> _items(String prefix, int count) {
  final now = DateTime.utc(2026, 1, 1);
  return List.generate(
    count,
    (index) => MediaItemEntity(
      id: '$prefix-$index',
      accountId: 'account',
      remoteId: '$prefix-$index',
      fileName: '$prefix-$index.jpg',
      mimeType: 'image/jpeg',
      mediaType: MediaType.photo,
      timestamp: now.subtract(Duration(minutes: index)),
      syncedAt: now,
    ),
  );
}

class _SearchCall {
  const _SearchCall(this.query, this.limit, this.offset);

  final String query;
  final int limit;
  final int offset;
}

class _SearchRepository implements MediaRepository {
  _SearchRepository(this.itemsByQuery, {this.pendingPage, this.onSearch});

  final Map<String, List<MediaItemEntity>> itemsByQuery;
  final Future<List<MediaItemEntity>>? Function(String query, int offset)?
  pendingPage;
  final FutureOr<List<MediaItemEntity>> Function(
    String query,
    int limit,
    int offset,
  )?
  onSearch;
  final List<_SearchCall> calls = [];

  @override
  Future<List<MediaItemEntity>> searchMedia(
    String query, {
    int limit = 100,
    int offset = 0,
  }) {
    calls.add(_SearchCall(query, limit, offset));
    final pending = pendingPage?.call(query, offset);
    if (pending != null) return pending;
    if (onSearch != null) {
      return Future.sync(() => onSearch!(query, limit, offset));
    }
    final matches = itemsByQuery[query] ?? const [];
    return Future.value(matches.skip(offset).take(limit).toList());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
