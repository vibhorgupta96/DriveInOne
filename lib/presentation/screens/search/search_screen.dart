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
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _debouncer.cancel();
    super.dispose();
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
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  )
                : null,
          ),
          onChanged: (value) {
            _debouncer.run(() {
              if (mounted) {
                setState(() => _query = value.trim());
              }
            });
          },
        ),
      ),
      body: _query.isEmpty
          ? const EmptyState(
              icon: Icons.search,
              title: 'Search your gallery',
              subtitle: 'Search by file name across all your cloud accounts.',
            )
          : _buildResults(),
    );
  }

  Widget _buildResults() {
    final results = ref.watch(searchResultsProvider(_query));

    return results.when(
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            title: 'No results for "$_query"',
            subtitle: 'Try a different search term.',
          );
        }
        return SingleChildScrollView(
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
            ],
          ),
        );
      },
      loading: () => const LoadingIndicator(),
      error: (error, _) => ErrorDisplayWidget(error: error),
    );
  }
}
