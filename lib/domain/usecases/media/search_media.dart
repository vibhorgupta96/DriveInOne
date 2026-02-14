import '../../entities/media_item.dart';
import '../../repositories/media_repository.dart';

class SearchMedia {
  final MediaRepository _repository;

  const SearchMedia(this._repository);

  Future<List<MediaItemEntity>> call(String query) =>
      _repository.searchByFileName(query);
}
