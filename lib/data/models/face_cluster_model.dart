import 'dart:typed_data';

class FaceClusterModel {
  final String id;
  final String? label;
  final String? representativeFaceId;
  final Uint8List? centroidEmbedding;
  final int faceCount;
  final DateTime createdAt;

  const FaceClusterModel({
    required this.id,
    this.label,
    this.representativeFaceId,
    this.centroidEmbedding,
    this.faceCount = 0,
    required this.createdAt,
  });
}
