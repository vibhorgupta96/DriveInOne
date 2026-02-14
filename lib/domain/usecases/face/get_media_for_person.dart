import '../../entities/media_item.dart';
import '../../repositories/face_repository.dart';

class GetMediaForPerson {
  final FaceRepository _repository;

  const GetMediaForPerson(this._repository);

  Future<List<MediaItemEntity>> call(String clusterId) =>
      _repository.getMediaForCluster(clusterId);
}
