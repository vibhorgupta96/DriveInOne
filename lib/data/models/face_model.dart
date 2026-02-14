import 'dart:typed_data';

class FaceModel {
  final String id;
  final String mediaItemId;
  final String boundingBox;
  final Uint8List embedding;
  final String? clusterId;
  final DateTime detectedAt;

  const FaceModel({
    required this.id,
    required this.mediaItemId,
    required this.boundingBox,
    required this.embedding,
    this.clusterId,
    required this.detectedAt,
  });
}
