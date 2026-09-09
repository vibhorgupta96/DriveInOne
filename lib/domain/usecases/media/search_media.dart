import '../../entities/media_item.dart';
import '../../repositories/media_repository.dart';

class SearchMedia {
  final MediaRepository _repository;

  const SearchMedia(this._repository);

  Future<List<MediaItemEntity>> call(
    String query, {
    int limit = 100,
    int offset = 0,
  }) => _repository.searchMedia(query, limit: limit, offset: offset);
}
