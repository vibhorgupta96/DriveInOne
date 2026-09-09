import 'package:flutter/material.dart';
import '../../../../domain/entities/media_item.dart';
import '../../timeline/widgets/media_grid.dart';

class SearchResults extends StatelessWidget {
  final List<MediaItemEntity> items;

  const SearchResults({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No results found'));
    }
    return SingleChildScrollView(child: MediaGrid(items: items));
  }
}
