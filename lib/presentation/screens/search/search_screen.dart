import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/debouncer.dart';
import '../../providers/media_providers.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/error_widget.dart';
import '../../widgets/common/loading_indicator.dart';
import '../timeline/widgets/media_grid.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _debouncer = Debouncer(delay: const Duration(milliseconds: 400));
  final _scrollController = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _debouncer.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _scrollController.position.pixels <
            _scrollController.position.maxScrollExtent - 400) {
      return;
    }
    ref.read(searchResultsProvider(_query).notifier).loadMore();
  }

  void _setQuery(String query) {
    if (_query == query) return;
    setState(() => _query = query);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: false,
          decoration: InputDecoration(
            hintText: 'Search photos and videos...',
            border: InputBorder.none,
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _debouncer.cancel();
                      _searchController.clear();
                      _setQuery('');
                    },
                  )
                : null,
          ),
          onChanged: (value) {
            _debouncer.run(() {
              if (mounted) {
                _setQuery(value.trim());
              }
            });
          },
        ),
      ),
      body: _query.isEmpty
          ? const EmptyState(
              icon: Icons.search,
              title: 'Search your gallery',
              subtitle:
                  'Search names, paths, file types, providers, and accounts.',
            )
          : _buildResults(),
    );
  }

  Widget _buildResults() {
    final results = ref.watch(searchResultsProvider(_query));

    return results.when(
      data: (searchResults) {
        final items = searchResults.items;
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            title: 'No results for "$_query"',
            subtitle: 'Try a different search term.',
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification ||
                notification is OverscrollNotification) {
              _onScroll();
            }
            return false;
          },
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '${items.length} results',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                MediaGrid(items: items),
                _SearchResultsFooter(
                  results: searchResults,
                  onRetry: () => ref
                      .read(searchResultsProvider(_query).notifier)
                      .loadMore(),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const LoadingIndicator(),
      error: (error, _) => ErrorDisplayWidget(
        error: error,
        onRetry: () =>
            ref.read(searchResultsProvider(_query).notifier).refresh(),
      ),
    );
  }
}

class _SearchResultsFooter extends StatelessWidget {
  const _SearchResultsFooter({required this.results, required this.onRetry});

  final SearchResultsState results;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (results.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (results.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry loading more'),
          ),
        ),
      );
    }
    if (!results.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'All ${results.items.length} results loaded',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}
