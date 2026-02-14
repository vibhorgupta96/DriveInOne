import 'dart:typed_data';
import '../../repositories/face_repository.dart';

class DetectFaces {
  final FaceRepository _repository;

  const DetectFaces(this._repository);

  Future<void> call(String mediaItemId, Uint8List thumbnailBytes) =>
      _repository.processMediaItem(mediaItemId, thumbnailBytes);
}
