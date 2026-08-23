import 'dart:typed_data';

import 'package:drive_in_one/data/datasources/local/face_clustering_service.dart';
import 'package:drive_in_one/data/datasources/local/face_embedding_service.dart';
import 'package:drive_in_one/data/models/face_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FaceModel face(String id, List<double> embedding) => FaceModel(
        id: id,
        mediaItemId: 'media-$id',
        boundingBox: '{}',
        embedding: FaceEmbeddingService.embeddingToBytes(embedding),
        detectedAt: DateTime.utc(2026),
      );

  test('clusters similar faces together and separates orthogonal faces', () {
    final result = FaceClusteringService().clusterFaces([
      face('a', [1, 0, 0]),
      face('b', [0.99, 0.01, 0]),
      face('c', [0, 1, 0]),
    ]);

    final assignments = {
      for (final assignment in result.assignments)
        assignment.faceId: assignment.clusterId,
    };
    expect(assignments['a'], assignments['b']);
    expect(assignments['c'], isNot(assignments['a']));
    expect(result.clusterCounts.values.toList()..sort(), [1, 2]);
  });

  test('reuses a matching existing cluster id', () {
    final result = FaceClusteringService().clusterFaces(
      [
        face('a', [1, 0])
      ],
      existingCentroids: {
        'known-person': [1, 0],
      },
    );

    expect(result.assignments.single.clusterId, 'known-person');
    expect(result.assignments.single.isNewCluster, isFalse);
    expect(result.clusterCounts, {'known-person': 1});
  });

  test('decodes only the requested byte view', () {
    final encoded = FaceEmbeddingService.embeddingToBytes([0.25, -0.5]);
    final padded = Uint8List(encoded.length + 8);
    padded.setRange(4, 4 + encoded.length, encoded);
    final view = Uint8List.view(padded.buffer, 4, encoded.length);

    expect(FaceEmbeddingService.bytesToEmbedding(view), [0.25, -0.5]);
  });
}
