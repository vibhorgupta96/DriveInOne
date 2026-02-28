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
    await delete(faces).go();
    await delete(faceClusters).go();
  }
}
