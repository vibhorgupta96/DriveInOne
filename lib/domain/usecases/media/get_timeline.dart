import '../../entities/media_item.dart';
import '../../repositories/media_repository.dart';

class GetTimeline {
  final MediaRepository _repository;

  const GetTimeline(this._repository);

  Future<List<MediaItemEntity>> call({
    required int limit,
    required int offset,
  }) => _repository.getTimeline(limit: limit, offset: offset);
}
