import 'dart:typed_data';
import 'package:equatable/equatable.dart';

class FaceEntity extends Equatable {
  final String id;
  final String mediaItemId;
  final String boundingBox; // JSON encoded
  final Uint8List embedding;
  final String? clusterId;
  final DateTime detectedAt;

  const FaceEntity({
    required this.id,
    required this.mediaItemId,
    required this.boundingBox,
    required this.embedding,
    this.clusterId,
    required this.detectedAt,
  });

  @override
  List<Object?> get props => [id, mediaItemId];
}
