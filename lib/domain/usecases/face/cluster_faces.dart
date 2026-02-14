import '../../repositories/face_repository.dart';

class ClusterFaces {
  final FaceRepository _repository;

  const ClusterFaces(this._repository);

  Future<void> call() => _repository.runClustering();
}
