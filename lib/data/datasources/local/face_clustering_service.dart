import 'dart:math';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../../core/constants/app_constants.dart';
import '../../models/face_model.dart';
import 'face_embedding_service.dart';

class ClusterAssignment {
  final String faceId;
  final String clusterId;
  final bool isNewCluster;

  const ClusterAssignment({
    required this.faceId,
    required this.clusterId,
    this.isNewCluster = false,
  });
}

class ClusterResult {
  final List<ClusterAssignment> assignments;
  final Map<String, Uint8List> clusterCentroids; // clusterId -> centroid bytes
  final Map<String, int> clusterCounts; // clusterId -> face count
  final Map<String, String> clusterRepresentatives; // clusterId -> faceId

  const ClusterResult({
    required this.assignments,
    required this.clusterCentroids,
    required this.clusterCounts,
    required this.clusterRepresentatives,
  });
}

class FaceClusteringService {
  static const _uuid = Uuid();

  /// Clusters faces using greedy centroid-matching.
  /// Each face is assigned to the nearest existing cluster if similarity > threshold,
  /// otherwise a new cluster is created.
  ClusterResult clusterFaces(
    List<FaceModel> faces, {
    Map<String, List<double>>? existingCentroids,
  }) {
    const threshold = AppConstants.faceSimilarityThreshold;
    final clusters = <String, List<FaceModel>>{}; // clusterId -> faces
    final centroids = <String, List<double>>{}; // clusterId -> centroid

    // Initialize with existing centroids if provided
    if (existingCentroids != null) {
      centroids.addAll(existingCentroids);
      for (final clusterId in existingCentroids.keys) {
        clusters[clusterId] = [];
      }
    }

    final assignments = <ClusterAssignment>[];

    for (final face in faces) {
      final embedding = FaceEmbeddingService.bytesToEmbedding(face.embedding);

      String? bestCluster;
      double bestSimilarity = 0;

      for (final entry in centroids.entries) {
        final sim = _cosineSimilarity(embedding, entry.value);
        if (sim > bestSimilarity && sim > threshold) {
          bestSimilarity = sim;
          bestCluster = entry.key;
        }
      }

      if (bestCluster != null) {
        clusters[bestCluster]!.add(face);
        // Update centroid as running average
        final allEmbeddings = clusters[bestCluster]!
            .map((f) => FaceEmbeddingService.bytesToEmbedding(f.embedding))
            .toList();
        centroids[bestCluster] = _averageEmbeddings(allEmbeddings);

        assignments.add(ClusterAssignment(
          faceId: face.id,
          clusterId: bestCluster,
        ));
      } else {
        final newClusterId = _uuid.v4();
        clusters[newClusterId] = [face];
        centroids[newClusterId] = embedding;

        assignments.add(ClusterAssignment(
          faceId: face.id,
          clusterId: newClusterId,
          isNewCluster: true,
        ));
      }
    }

    // Build result
    final centroidBytes = <String, Uint8List>{};
    final counts = <String, int>{};
    final representatives = <String, String>{};

    for (final entry in clusters.entries) {
      if (entry.value.isEmpty) continue;
      centroidBytes[entry.key] = FaceEmbeddingService.embeddingToBytes(
        centroids[entry.key]!,
      );
      counts[entry.key] = entry.value.length;
      representatives[entry.key] = entry.value.first.id;
    }

    return ClusterResult(
      assignments: assignments,
      clusterCentroids: centroidBytes,
      clusterCounts: counts,
      clusterRepresentatives: representatives,
    );
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = sqrt(normA) * sqrt(normB);
    if (denom == 0) return 0;
    return dot / denom;
  }

  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    final dim = embeddings.first.length;
    final avg = List.filled(dim, 0.0);
    for (final emb in embeddings) {
      for (int i = 0; i < dim; i++) {
        avg[i] += emb[i];
      }
    }
    for (int i = 0; i < dim; i++) {
      avg[i] /= embeddings.length;
    }
    // L2 normalize the centroid
    final norm = sqrt(avg.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) {
      for (int i = 0; i < dim; i++) {
        avg[i] /= norm;
      }
    }
    return avg;
  }
}
