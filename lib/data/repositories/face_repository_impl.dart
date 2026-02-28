import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_constants.dart';
import '../../core/enums/media_type.dart';
import '../../core/constants/provider_constants.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/face_cluster.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/face_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../datasources/local/secure_storage_source.dart';
import '../database/app_database.dart';
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
  final SecureStorageSource secureStorage;
  final Dio _dio = Dio();

  static const _uuid = Uuid();

  FaceRepositoryImpl({
    required this.faceDetectionService,
    required this.faceEmbeddingService,
    required this.faceClusteringService,
    required this.facesDao,
    required this.mediaItemsDao,
    required this.mediaRepository,
    required this.secureStorage,
  });

  @override
  Future<void> processMediaItem(String mediaItemId, Uint8List thumbnailBytes) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/face_detect_$mediaItemId.jpg');
      await tempFile.writeAsBytes(thumbnailBytes);

      final detectedFaces =
          await faceDetectionService.detectFacesFromFile(tempFile.path);

      if (detectedFaces.isEmpty) {
        await mediaItemsDao.markFacesProcessed(mediaItemId);
        await tempFile.delete().catchError((_) {});
        return;
      }

      for (final detected in detectedFaces) {
        try {
          final rect = detected.boundingBox;
          final faceSize =
              rect.width > rect.height ? rect.width : rect.height;

          if (faceSize < AppConstants.minFaceSizePixels) continue;

          final yAngle = detected.headEulerAngleY;
          if (yAngle != null &&
              yAngle.abs() > AppConstants.maxHeadEulerAngleY) {
            continue;
          }
          final zAngle = detected.headEulerAngleZ;
          if (zAngle != null &&
              zAngle.abs() > AppConstants.maxHeadEulerAngleZ) {
            continue;
          }

          final croppedBytes = ImageUtils.cropAndAlignFace(
            thumbnailBytes,
            left: rect.left.toInt(),
            top: rect.top.toInt(),
            width: rect.width.toInt(),
            height: rect.height.toInt(),
            padding: AppConstants.facePaddingRatio,
            eyeAngleDegrees: detected.eyeRotationDegrees,
          );

          final embedding =
              await faceEmbeddingService.getEmbedding(croppedBytes);
          final embeddingBytes =
              FaceEmbeddingService.embeddingToBytes(embedding);

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
      rethrow;
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

      // Apply face -> cluster assignments.
      for (final assignment in result.assignments) {
        await facesDao.updateFaceCluster(assignment.faceId, assignment.clusterId);
      }

      // Persist cluster stats once per final cluster state.
      final existingClusterIds = existingClusters.map((c) => c.id).toSet();
      final finalClusterIds = result.clusterCentroids.keys.toSet();

      for (final clusterId in finalClusterIds) {
        final centroid = result.clusterCentroids[clusterId];
        if (centroid == null) continue;
        final count = result.clusterCounts[clusterId] ?? 0;
        final representativeFaceId = result.clusterRepresentatives[clusterId];

        if (existingClusterIds.contains(clusterId)) {
          await facesDao.updateClusterStats(
            clusterId,
            centroid: centroid,
            count: count,
            representativeFaceId: representativeFaceId,
          );
        } else {
          await facesDao.insertCluster(FaceClustersCompanion(
            id: Value(clusterId),
            representativeFaceId: Value(representativeFaceId),
            centroidEmbedding: Value(centroid),
            faceCount: Value(count),
          ));
        }
      }

      // Remove stale clusters that ended up with zero assigned faces after reclustering.
      for (final cluster in existingClusters) {
        if (!finalClusterIds.contains(cluster.id)) {
          await facesDao.deleteCluster(cluster.id);
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
    return clusters.map<FaceClusterEntity>(_mapClusterToEntity).toList();
  }

  @override
  Stream<List<FaceClusterEntity>> watchClusters() {
    return facesDao.watchClusters().map(
      (clusters) => clusters.map<FaceClusterEntity>(_mapClusterToEntity).toList(),
    );
  }

  @override
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId) async {
    final mediaIds = await facesDao.getMediaIdsForCluster(clusterId);
    return mediaRepository.getMediaItemsByIds(mediaIds);
  }

  @override
  Future<MediaItemEntity?> getRepresentativeMediaForCluster(String clusterId) async {
    final cluster = await facesDao.getClusterById(clusterId);
    final representativeFaceId = cluster?.representativeFaceId;

    if (representativeFaceId != null && representativeFaceId.isNotEmpty) {
      final face = await facesDao.getFaceById(representativeFaceId);
      if (face != null) {
        return mediaRepository.getMediaItemById(face.mediaItemId);
      }
    }

    // Fallback for old clusters that do not have representativeFaceId.
    final mediaIds = await facesDao.getMediaIdsForCluster(clusterId);
    if (mediaIds.isEmpty) return null;
    return mediaRepository.getMediaItemById(mediaIds.first);
  }

  @override
  Future<Uint8List?> getRepresentativeFaceThumbnail(String clusterId) async {
    final cluster = await facesDao.getClusterById(clusterId);
    final representativeFaceId = cluster?.representativeFaceId;
    if (representativeFaceId == null || representativeFaceId.isEmpty) return null;

    final face = await facesDao.getFaceById(representativeFaceId);
    if (face == null) return null;

    final media = await mediaRepository.getMediaItemById(face.mediaItemId);
    if (media == null) return null;

    final sourceBytes = await _downloadMediaThumbnail(media);
    if (sourceBytes == null) return null;

    final box = _parseBoundingBox(face.boundingBox);
    if (box == null) return sourceBytes;

    final image = img.decodeImage(sourceBytes);
    if (image == null) return sourceBytes;

    final left = (box['left'] ?? 0).toInt();
    final top = (box['top'] ?? 0).toInt();
    final width = (box['width'] ?? 0).toInt();
    final height = (box['height'] ?? 0).toInt();

    // Tight crop so face bubbles clearly identify each person.
    final crop = ImageUtils.cropFace(sourceBytes, left, top, width, height);
    return crop;
  }

  @override
  Future<void> renameCluster(String clusterId, String name) async {
    await facesDao.updateClusterLabel(clusterId, name);
  }

  @override
  Future<void> resetAllFaceData() async {
    await facesDao.deleteAllFacesAndClusters();
    await mediaItemsDao.resetAllFacesProcessed();
    AppLogger.info('Reset all face data: cleared faces, clusters, and processing flags');
  }

  @override
  Future<Map<String, int>> getDiagnosticCounts() async {
    final faceCount = await facesDao.getFaceCount();
    final clusterCount = await facesDao.getClusterCount();
    final totalMedia = await mediaItemsDao.getMediaCount();
    final processedCount = await mediaItemsDao.getProcessedFacesCount();
    final unclusteredCount = (await facesDao.getAllUnclusteredFaces()).length;
    return {
      'faces': faceCount,
      'clusters': clusterCount,
      'totalMedia': totalMedia,
      'processedMedia': processedCount,
      'unprocessedMedia': totalMedia - processedCount,
      'unclusteredFaces': unclusteredCount,
    };
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

  Map<String, double>? _parseBoundingBox(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return {
        'left': (map['left'] as num?)?.toDouble() ?? 0,
        'top': (map['top'] as num?)?.toDouble() ?? 0,
        'width': (map['width'] as num?)?.toDouble() ?? 0,
        'height': (map['height'] as num?)?.toDouble() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _downloadMediaThumbnail(MediaItemEntity media) async {
    final token = await secureStorage.getAccessToken(media.accountId);
    if (token == null || token.isEmpty) return null;
    final headers = {'Authorization': 'Bearer $token'};

    var thumbnailUrl = media.thumbnailUrl;
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
      if (media.accountId.startsWith('dropbox|') &&
          media.remotePath != null &&
          media.remotePath!.isNotEmpty) {
        thumbnailUrl = 'dropbox://thumbnail${media.remotePath}';
      } else if (media.accountId.startsWith('google|')) {
        thumbnailUrl = 'gdrive://thumb/${media.remoteId}';
      } else if (media.accountId.startsWith('onedrive|')) {
        thumbnailUrl = '${ProviderConstants.graphBaseUrl}/me/drive/items/${media.remoteId}/thumbnails/0/large/content';
      }
    }
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) return null;

    if (thumbnailUrl.startsWith('gdrive://thumb/')) {
      final fileId = thumbnailUrl.replaceFirst('gdrive://thumb/', '');
      final metaResponse = await _dio.get(
        '${ProviderConstants.googleDriveBaseUrl}/files/$fileId',
        queryParameters: const {'fields': 'thumbnailLink'},
        options: Options(headers: headers),
      );
      final freshLink = metaResponse.data['thumbnailLink'] as String?;
      if (freshLink == null || freshLink.isEmpty) return null;
      final upgradedLink = freshLink.replaceFirst(RegExp(r'=s\d+'), '=s800');
      final thumbResponse = await _dio.get(
        upgradedLink,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(List<int>.from(thumbResponse.data as List));
    }

    if (thumbnailUrl.startsWith('dropbox://thumbnail')) {
      final path = thumbnailUrl.replaceFirst('dropbox://thumbnail', '');
      final apiArg = jsonEncode({
        'resource': {'.tag': 'path', 'path': path},
        'format': 'jpeg',
        'size': 'w256h256',
      });
      final response = await _dio.post(
        '${ProviderConstants.dropboxContentBaseUrl}/files/get_thumbnail_v2',
        options: Options(
          headers: {...headers, 'Dropbox-API-Arg': apiArg},
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(List<int>.from(response.data as List));
    }

    final response = await _dio.get(
      thumbnailUrl,
      options: Options(headers: headers, responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(List<int>.from(response.data as List));
  }
}
