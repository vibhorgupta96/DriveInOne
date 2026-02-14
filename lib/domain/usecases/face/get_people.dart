import '../../entities/face_cluster.dart';
import '../../repositories/face_repository.dart';

class GetPeople {
  final FaceRepository _repository;

  const GetPeople(this._repository);

  Stream<List<FaceClusterEntity>> call() => _repository.watchClusters();
}
