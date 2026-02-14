import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums/media_type.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/face_cluster.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/face_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../database/daos/faces_dao.dart';
import '../database/daos/media_items_dao.dart';
import '../database/tables/media_items_table.dart';
import '../datasources/local/face_clustering_service.dart';
import '../datasources/local/face_detection_service.dart';
import '../datasources/local/face_embedding_service.dart';
import '../models/face_model.dart';

class FaceRepositoryImpl implements FaceRepository {
  final FaceDetectionService faceDetectionService;
  final FaceEmbeddingService faceEmbeddingService;
  final FaceClusteringService faceClusteringService;
  final FacesDao facesDao;
  final MediaItemsDao mediaItemsDao;
  final MediaRepository mediaRepository;

  static const _uuid = Uuid();

  FaceRepositoryImpl({
    required this.faceDetectionService,
    required this.faceEmbeddingService,
    required this.faceClusteringService,
    required this.facesDao,
    required this.mediaItemsDao,
    required this.mediaRepository,
  });

  @override
  Future<void> processMediaItem(String mediaItemId, Uint8List thumbnailBytes) async {
    try {
      // Save thumbnail to temp file for ML Kit
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/face_detect_$mediaItemId.jpg');
      await tempFile.writeAsBytes(thumbnailBytes);

      // Detect faces
      final faceRects = await faceDetectionService.detectFacesFromFile(tempFile.path);

      if (faceRects.isEmpty) {
        await mediaItemsDao.markFacesProcessed(mediaItemId);
        await tempFile.delete().catchError((_) {});
        return;
      }

      // Process each detected face
      for (final rect in faceRects) {
        try {
          // Crop face from thumbnail
          final croppedBytes = ImageUtils.cropFace(
            thumbnailBytes,
            rect.left.toInt(),
            rect.top.toInt(),
            rect.width.toInt(),
            rect.height.toInt(),
          );

          // Generate embedding
          final embedding = await faceEmbeddingService.getEmbedding(croppedBytes);
          final embeddingBytes = FaceEmbeddingService.embeddingToBytes(embedding);

          // Store face in DB
          final faceId = _uuid.v4();
          final boundingBox = jsonEncode({
            'left': rect.left,
            'top': rect.top,
            'width': rect.width,
            'height': rect.height,
          });

          await facesDao.insertFace(FacesCompanion(
            id: Value(faceId),
            mediaItemId: Value(mediaItemId),
            boundingBox: Value(boundingBox),
            embedding: Value(embeddingBytes),
          ));
        } catch (e) {
          AppLogger.error('Failed to process face in $mediaItemId', error: e);
        }
      }

      await mediaItemsDao.markFacesProcessed(mediaItemId);
      await tempFile.delete().catchError((_) {});
    } catch (e) {
      AppLogger.error('Face processing failed for $mediaItemId', error: e);
    }
  }

  @override
  Future<void> runClustering() async {
    try {
      final allFaces = await facesDao.getAllFaces();
      if (allFaces.isEmpty) return;

      // Convert DB face objects to FaceModel
      final faceModels = allFaces.map((f) => FaceModel(
        id: f.id,
        mediaItemId: f.mediaItemId,
        boundingBox: f.boundingBox,
        embedding: f.embedding,
        clusterId: f.clusterId,
        detectedAt: f.detectedAt,
      )).toList();

      // Load existing cluster centroids
      final existingClusters = await facesDao.getAllClusters();
      final existingCentroids = <String, List<double>>{};
      for (final cluster in existingClusters) {
        if (cluster.centroidEmbedding != null) {
          existingCentroids[cluster.id] =
              FaceEmbeddingService.bytesToEmbedding(cluster.centroidEmbedding!);
        }
      }

      // Run clustering
      final result = faceClusteringService.clusterFaces(
        faceModels,
        existingCentroids: existingCentroids.isNotEmpty ? existingCentroids : null,
      );

      // Apply assignments
      for (final assignment in result.assignments) {
        await facesDao.updateFaceCluster(assignment.faceId, assignment.clusterId);

        if (assignment.isNewCluster) {
          await facesDao.insertCluster(FaceClustersCompanion(
            id: Value(assignment.clusterId),
            representativeFaceId: Value(result.clusterRepresentatives[assignment.clusterId]),
            centroidEmbedding: Value(result.clusterCentroids[assignment.clusterId]),
            faceCount: Value(result.clusterCounts[assignment.clusterId] ?? 1),
          ));
        } else {
          final centroid = result.clusterCentroids[assignment.clusterId];
          final count = result.clusterCounts[assignment.clusterId] ?? 0;
          if (centroid != null) {
            await facesDao.updateClusterCentroid(assignment.clusterId, centroid, count);
          }
        }
      }

      AppLogger.info('Clustering complete: ${result.assignments.length} faces, '
          '${result.clusterCentroids.length} clusters');
    } catch (e) {
      AppLogger.error('Clustering failed', error: e);
    }
  }

  @override
  Future<List<FaceClusterEntity>> getClusters() async {
    final clusters = await facesDao.getAllClusters();
    return clusters.map(_mapClusterToEntity).toList();
  }

  @override
  Stream<List<FaceClusterEntity>> watchClusters() {
    return facesDao.watchClusters().map(
      (clusters) => clusters.map(_mapClusterToEntity).toList(),
    );
  }

  @override
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId) async {
    final mediaIds = await facesDao.getMediaIdsForCluster(clusterId);
    return mediaRepository.getMediaItemsByIds(mediaIds);
  }

  @override
  Future<void> renameCluster(String clusterId, String name) async {
    await facesDao.updateClusterLabel(clusterId, name);
  }

  FaceClusterEntity _mapClusterToEntity(FaceCluster cluster) {
    return FaceClusterEntity(
      id: cluster.id,
      label: cluster.label,
      representativeFaceId: cluster.representativeFaceId,
      centroidEmbedding: cluster.centroidEmbedding,
      faceCount: cluster.faceCount,
      createdAt: cluster.createdAt,
    );
  }
}
