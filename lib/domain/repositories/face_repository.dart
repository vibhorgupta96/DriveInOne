import 'dart:typed_data';
import '../entities/face_cluster.dart';
import '../entities/media_item.dart';

/// Immutable media identity captured before network work starts.
///
/// A face scan may take long enough for sync or unlink to replace the local
/// row.  Commits using this context must only affect that exact revision.
class FaceProcessingContext {
  const FaceProcessingContext({
    required this.accountId,
    required this.fileHash,
    required this.syncedAt,
    required this.accountGeneration,
  });

  final String accountId;
  final String? fileHash;
  final DateTime syncedAt;
  final int accountGeneration;
}

abstract class FaceRepository {
  /// Processes [thumbnailBytes] and any distinct [additionalFrames] as one
  /// complete replacement for the media item.  [expectedSource] is optional
  /// so existing direct callers remain supported.
  Future<void> processMediaItem(
    String mediaItemId,
    Uint8List thumbnailBytes, {
    List<Uint8List> additionalFrames = const [],
    FaceProcessingContext? expectedSource,
  });
  Future<void> runClustering();
  Future<List<FaceClusterEntity>> getClusters();
  Stream<List<FaceClusterEntity>> watchClusters();
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId);
  Stream<List<MediaItemEntity>> watchMediaForCluster(String clusterId);
  Future<MediaItemEntity?> getRepresentativeMediaForCluster(String clusterId);
  Stream<MediaItemEntity?> watchRepresentativeMediaForCluster(String clusterId);
  Future<Uint8List?> getRepresentativeFaceThumbnail(String clusterId);
  Stream<Uint8List?> watchRepresentativeFaceThumbnail(String clusterId);
  Future<void> renameCluster(String clusterId, String name);
  Future<void> resetAllFaceData();
  Future<Map<String, int>> getDiagnosticCounts();
}
