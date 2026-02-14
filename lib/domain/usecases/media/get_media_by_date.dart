import '../../entities/media_item.dart';
import '../../repositories/media_repository.dart';

class GetMediaByDate {
  final MediaRepository _repository;

  const GetMediaByDate(this._repository);

  Future<List<MediaItemEntity>> call(DateTime start, DateTime end) =>
      _repository.getMediaByDateRange(start, end);
}
