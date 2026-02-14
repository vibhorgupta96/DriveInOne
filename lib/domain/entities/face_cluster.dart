import 'dart:typed_data';
import 'package:equatable/equatable.dart';

class FaceClusterEntity extends Equatable {
  final String id;
  final String? label;
  final String? representativeFaceId;
  final Uint8List? centroidEmbedding;
  final int faceCount;
  final DateTime createdAt;

  const FaceClusterEntity({
    required this.id,
    this.label,
    this.representativeFaceId,
    this.centroidEmbedding,
    this.faceCount = 0,
    required this.createdAt,
  });

  String get displayName => label ?? 'Person ${id.substring(0, 4)}';

  @override
  List<Object?> get props => [id];
}
