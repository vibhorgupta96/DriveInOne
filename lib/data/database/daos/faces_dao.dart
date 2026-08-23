import 'dart:typed_data';

import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/faces_table.dart';
import '../tables/face_clusters_table.dart';

part 'faces_dao.g.dart';

@DriftAccessor(tables: [Faces, FaceClusters])
class FacesDao extends DatabaseAccessor<AppDatabase> with _$FacesDaoMixin {
  FacesDao(super.db);

  Future<void> insertFace(FacesCompanion face) =>
      into(faces).insert(face, mode: InsertMode.insertOrReplace);

  /// Replaces the complete detected-face result for one media item.
  ///
  /// Callers should finish detection and embedding before invoking this method.
  /// The transaction then guarantees that a retry cannot leave a mixture of
  /// old and new randomly identified face rows.
  Future<void> replaceFacesForMedia(
    String mediaItemId,
    List<FacesCompanion> replacements,
  ) {
    return transaction(() async {
      await (delete(faces)..where((f) => f.mediaItemId.equals(mediaItemId)))
          .go();
      for (final face in replacements) {
        await into(faces).insert(face);
      }
      await _repairClusterReferences();
    });
  }

  Future<List<Face>> getFacesByMedia(String mediaItemId) =>
      (select(faces)..where((f) => f.mediaItemId.equals(mediaItemId))).get();

  Future<Face?> getFaceById(String faceId) =>
      (select(faces)..where((f) => f.id.equals(faceId))).getSingleOrNull();

  Future<List<Face>> getAllUnclusteredFaces() =>
      (select(faces)..where((f) => f.clusterId.isNull())).get();

  Future<List<Face>> getAllFaces() => select(faces).get();

  Future<void> updateFaceCluster(String faceId, String clusterId) =>
      (update(faces)..where((f) => f.id.equals(faceId)))
          .write(FacesCompanion(clusterId: Value(clusterId)));

  // Face Clusters
  Future<List<FaceCluster>> getAllClusters() =>
      (select(faceClusters)..orderBy([(c) => OrderingTerm.desc(c.faceCount)]))
          .get();

  Stream<List<FaceCluster>> watchClusters() =>
      (select(faceClusters)..orderBy([(c) => OrderingTerm.desc(c.faceCount)]))
          .watch();

  Future<void> insertCluster(FaceClustersCompanion cluster) =>
      into(faceClusters).insert(cluster, mode: InsertMode.insertOrReplace);

  Future<void> updateClusterLabel(String clusterId, String label) =>
      (update(faceClusters)..where((c) => c.id.equals(clusterId)))
          .write(FaceClustersCompanion(label: Value(label)));

  Future<void> updateClusterCentroid(
          String clusterId, Uint8List centroid, int count) =>
      (update(faceClusters)..where((c) => c.id.equals(clusterId))).write(
          FaceClustersCompanion(
              centroidEmbedding: Value(centroid), faceCount: Value(count)));

  Future<void> updateClusterStats(
    String clusterId, {
    required Uint8List centroid,
    required int count,
    required String? representativeFaceId,
  }) =>
      (update(faceClusters)..where((c) => c.id.equals(clusterId))).write(
        FaceClustersCompanion(
          centroidEmbedding: Value(centroid),
          faceCount: Value(count),
          representativeFaceId: Value(representativeFaceId),
        ),
      );

  /// Atomically applies a complete clustering result while preserving labels
  /// on clusters that continue to exist.
  Future<void> replaceClusterState({
    required Map<String, String> assignments,
    required Map<String, Uint8List> centroids,
    required Map<String, int> counts,
    required Map<String, String?> representatives,
  }) {
    return transaction(() async {
      await update(faces).write(
        const FacesCompanion(clusterId: Value(null)),
      );

      for (final entry in assignments.entries) {
        await (update(faces)..where((f) => f.id.equals(entry.key))).write(
          FacesCompanion(clusterId: Value(entry.value)),
        );
      }

      final existingClusters = await select(faceClusters).get();
      final existingIds = existingClusters.map((cluster) => cluster.id).toSet();
      final finalIds = centroids.keys.toSet();

      for (final clusterId in finalIds) {
        final centroid = centroids[clusterId];
        if (centroid == null) continue;
        final companion = FaceClustersCompanion(
          centroidEmbedding: Value(centroid),
          faceCount: Value(counts[clusterId] ?? 0),
          representativeFaceId: Value(representatives[clusterId]),
        );
        if (existingIds.contains(clusterId)) {
          await (update(faceClusters)
                ..where((cluster) => cluster.id.equals(clusterId)))
              .write(companion);
        } else {
          await into(faceClusters).insert(
            companion.copyWith(id: Value(clusterId)),
          );
        }
      }

      for (final staleCluster in existingClusters
          .where((cluster) => !finalIds.contains(cluster.id))) {
        await (delete(faceClusters)
              ..where((cluster) => cluster.id.equals(staleCluster.id)))
            .go();
      }
    });
  }

  Future<List<String>> getMediaIdsForCluster(String clusterId) async {
    final query = select(faces)..where((f) => f.clusterId.equals(clusterId));
    final results = await query.get();
    return results.map((f) => f.mediaItemId).toSet().toList();
  }

  Future<void> deleteCluster(String clusterId) async {
    await (update(faces)..where((f) => f.clusterId.equals(clusterId)))
        .write(const FacesCompanion(clusterId: Value(null)));
    await (delete(faceClusters)..where((c) => c.id.equals(clusterId))).go();
  }

  /// Deletes faces for one media item and repairs affected cluster metadata.
  Future<void> deleteFacesForMedia(String mediaItemId) =>
      deleteFacesForMediaIds([mediaItemId]);

  /// Deletes faces for several media items in one transaction.
  Future<void> deleteFacesForMediaIds(Iterable<String> mediaItemIds) async {
    final ids = mediaItemIds.toSet();
    if (ids.isEmpty) return;

    await transaction(() async {
      await (delete(faces)..where((f) => f.mediaItemId.isIn(ids))).go();
      await _repairClusterReferences();
    });
  }

  /// Deletes face rows belonging to an account before its media rows are
  /// removed. The account/media cleanup transaction should invoke this first.
  Future<void> deleteFacesForAccount(String accountId) async {
    await transaction(() async {
      await customUpdate(
        'DELETE FROM faces WHERE media_item_id IN '
        '(SELECT id FROM media_items WHERE account_id = ?)',
        variables: [Variable.withString(accountId)],
        updates: {faces},
      );
      await _repairClusterReferences();
    });
  }

  /// Removes empty clusters and recomputes derived cluster state left behind
  /// by media deletion.
  Future<void> pruneOrphanClusters() => transaction(_repairClusterReferences);

  Future<void> _repairClusterReferences() async {
    final clusters = await select(faceClusters).get();
    for (final cluster in clusters) {
      final remainingFaces = await (select(faces)
            ..where((face) => face.clusterId.equals(cluster.id)))
          .get();
      if (remainingFaces.isEmpty) {
        await (delete(faceClusters)..where((c) => c.id.equals(cluster.id)))
            .go();
        continue;
      }

      final representativeStillExists = cluster.representativeFaceId != null &&
          remainingFaces.any((face) => face.id == cluster.representativeFaceId);
      await (update(faceClusters)..where((c) => c.id.equals(cluster.id))).write(
        FaceClustersCompanion(
          centroidEmbedding: Value(_averageEmbedding(remainingFaces)),
          faceCount: Value(remainingFaces.length),
          representativeFaceId: Value(
            representativeStillExists
                ? cluster.representativeFaceId
                : remainingFaces.first.id,
          ),
        ),
      );
    }
  }

  Uint8List _averageEmbedding(List<Face> clusterFaces) {
    final byteLength = clusterFaces.first.embedding.length;
    if (byteLength % Float32List.bytesPerElement != 0) {
      throw StateError('Invalid face embedding byte length');
    }
    final valueCount = byteLength ~/ Float32List.bytesPerElement;
    final sums = Float64List(valueCount);

    for (final face in clusterFaces) {
      if (face.embedding.length != byteLength) {
        throw StateError('Inconsistent face embedding sizes in a cluster');
      }
      final bytes = ByteData.sublistView(face.embedding);
      for (var index = 0; index < valueCount; index++) {
        sums[index] += bytes.getFloat32(
          index * Float32List.bytesPerElement,
          Endian.host,
        );
      }
    }

    final centroid = Uint8List(byteLength);
    final centroidBytes = ByteData.sublistView(centroid);
    for (var index = 0; index < valueCount; index++) {
      centroidBytes.setFloat32(
        index * Float32List.bytesPerElement,
        sums[index] / clusterFaces.length,
        Endian.host,
      );
    }
    return centroid;
  }

  Future<FaceCluster?> getClusterById(String id) =>
      (select(faceClusters)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<int> getFaceCount() async {
    final count = countAll();
    final query = selectOnly(faces)..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<int> getClusterCount() async {
    final count = countAll();
    final query = selectOnly(faceClusters)..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<void> deleteAllFacesAndClusters() async {
    await transaction(() async {
      await delete(faces).go();
      await delete(faceClusters).go();
    });
  }
}
