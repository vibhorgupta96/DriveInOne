import 'dart:typed_data';
import '../entities/face_cluster.dart';
import '../entities/media_item.dart';

abstract class FaceRepository {
  Future<void> processMediaItem(String mediaItemId, Uint8List thumbnailBytes);
  Future<void> runClustering();
  Future<List<FaceClusterEntity>> getClusters();
  Stream<List<FaceClusterEntity>> watchClusters();
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId);
  Future<MediaItemEntity?> getRepresentativeMediaForCluster(String clusterId);
  Future<Uint8List?> getRepresentativeFaceThumbnail(String clusterId);
  Future<void> renameCluster(String clusterId, String name);
  Future<void> resetAllFaceData();
  Future<Map<String, int>> getDiagnosticCounts();
}
