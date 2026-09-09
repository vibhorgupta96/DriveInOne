import 'dart:isolate';
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

/// Immutable, isolate-safe input for [FaceClusteringService.clusterFacesInWorker].
///
/// It contains only face identifiers, embedding bytes, and primitive collection
/// types, so database records and repository objects never cross the isolate
/// boundary.
class FaceClusteringWorkerInput {
  const FaceClusteringWorkerInput({
    required this.faces,
    this.existingCentroids = const {},
  });

  factory FaceClusteringWorkerInput.fromFaces(
    List<FaceModel> faces, {
    Map<String, List<double>>? existingCentroids,
  }) {
    return FaceClusteringWorkerInput(
      faces: [
        for (final face in faces)
          FaceClusteringWorkerFace(
            id: face.id,
            embedding: Uint8List.fromList(face.embedding),
          ),
      ],
      existingCentroids: {
        for (final entry
            in (existingCentroids ?? const <String, List<double>>{}).entries)
          entry.key: List<double>.from(entry.value, growable: false),
      },
    );
  }

  final List<FaceClusteringWorkerFace> faces;
  final Map<String, List<double>> existingCentroids;
}

class FaceClusteringWorkerFace {
  const FaceClusteringWorkerFace({required this.id, required this.embedding});

  final String id;
  final Uint8List embedding;
}

class FaceClusteringWorkerAssignment {
  const FaceClusteringWorkerAssignment({
    required this.faceId,
    required this.clusterId,
    required this.isNewCluster,
  });

  final String faceId;
  final String clusterId;
  final bool isNewCluster;
}

/// Immutable, isolate-safe output for [FaceClusteringService.clusterFacesInWorker].
class FaceClusteringWorkerResult {
  const FaceClusteringWorkerResult({
    required this.assignments,
    required this.clusterCentroids,
    required this.clusterCounts,
    required this.clusterRepresentatives,
  });

  final List<FaceClusteringWorkerAssignment> assignments;
  final Map<String, Uint8List> clusterCentroids;
  final Map<String, int> clusterCounts;
  final Map<String, String> clusterRepresentatives;

  ClusterResult toClusterResult() {
    return ClusterResult(
      assignments: [
        for (final assignment in assignments)
          ClusterAssignment(
            faceId: assignment.faceId,
            clusterId: assignment.clusterId,
            isNewCluster: assignment.isNewCluster,
          ),
      ],
      clusterCentroids: clusterCentroids,
      clusterCounts: clusterCounts,
      clusterRepresentatives: clusterRepresentatives,
    );
  }
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
    return _cluster(
      FaceClusteringWorkerInput.fromFaces(
        faces,
        existingCentroids: existingCentroids,
      ),
    ).toClusterResult();
  }

  /// Runs the same deterministic clustering algorithm away from the UI isolate.
  ///
  /// [FaceClusteringWorkerInput] and [FaceClusteringWorkerResult] deliberately
  /// contain only sendable values. Callers can convert the result with
  /// [FaceClusteringWorkerResult.toClusterResult] before persisting it.
  Future<FaceClusteringWorkerResult> clusterFacesInWorker(
    FaceClusteringWorkerInput input,
  ) {
    return Isolate.run(() => faceClusteringWorkerEntry(input));
  }

  FaceClusteringWorkerResult _cluster(FaceClusteringWorkerInput input) {
    const threshold = AppConstants.faceSimilarityThreshold;
    final members = <String, List<FaceClusteringWorkerFace>>{};
    final matchingCentroids = <String, List<double>>{};
    final rawSums = <String, List<double>>{};
    final counts = <String, int>{};

    // Initialize with existing centroids if provided
    for (final entry in input.existingCentroids.entries) {
      matchingCentroids[entry.key] = List<double>.from(
        entry.value,
        growable: false,
      );
      // Existing clusters have no member vectors in this run. Their centroid
      // guides the first match, but it must not be treated as one of the new
      // faces when calculating this run's raw aggregate and count.
      rawSums[entry.key] = List<double>.filled(entry.value.length, 0);
      counts[entry.key] = 0;
      members[entry.key] = [];
    }

    final assignments = <FaceClusteringWorkerAssignment>[];

    for (final face in input.faces) {
      final embedding = FaceEmbeddingService.bytesToEmbedding(face.embedding);

      String? bestCluster;
      double bestSimilarity = 0;

      for (final entry in matchingCentroids.entries) {
        final similarity = _cosineSimilarity(embedding, entry.value);
        if (similarity > bestSimilarity && similarity > threshold) {
          bestSimilarity = similarity;
          bestCluster = entry.key;
        }
      }

      if (bestCluster != null) {
        final clusterMembers = members[bestCluster]!;
        final rawSum = rawSums[bestCluster]!;
        clusterMembers.add(face);
        for (var index = 0; index < embedding.length; index++) {
          rawSum[index] += embedding[index];
        }
        counts[bestCluster] = counts[bestCluster]! + 1;
        matchingCentroids[bestCluster] = rawSum;

        assignments.add(
          FaceClusteringWorkerAssignment(
            faceId: face.id,
            clusterId: bestCluster,
            isNewCluster: false,
          ),
        );
      } else {
        final newClusterId = _uuid.v4();
        final rawSum = List<double>.from(embedding, growable: false);
        members[newClusterId] = [face];
        rawSums[newClusterId] = rawSum;
        matchingCentroids[newClusterId] = rawSum;
        counts[newClusterId] = 1;

        assignments.add(
          FaceClusteringWorkerAssignment(
            faceId: face.id,
            clusterId: newClusterId,
            isNewCluster: true,
          ),
        );
      }
    }

    // Build result
    final centroidBytes = <String, Uint8List>{};
    final representatives = <String, String>{};

    for (final entry in members.entries) {
      if (entry.value.isEmpty) continue;
      centroidBytes[entry.key] = FaceEmbeddingService.embeddingToBytes(
        _normalizedCopy(rawSums[entry.key]!),
      );
      representatives[entry.key] = entry.value.first.id;
    }

    return FaceClusteringWorkerResult(
      assignments: assignments,
      clusterCentroids: centroidBytes,
      clusterCounts: {
        for (final entry in counts.entries)
          if (entry.value > 0) entry.key: entry.value,
      },
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

  List<double> _normalizedCopy(List<double> values) {
    final normalized = List<double>.from(values, growable: false);
    final norm = sqrt(normalized.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) {
      for (int i = 0; i < normalized.length; i++) {
        normalized[i] /= norm;
      }
    }
    return normalized;
  }
}

/// Top-level isolate entry point; it must remain free of repository or database
/// state so [FaceClusteringWorkerInput] can cross isolate boundaries safely.
FaceClusteringWorkerResult faceClusteringWorkerEntry(
  FaceClusteringWorkerInput input,
) {
  return FaceClusteringService()._cluster(input);
}
