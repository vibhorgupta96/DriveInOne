import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/face_cluster.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/face_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../datasources/local/secure_storage_source.dart';
import '../datasources/local/thumbnail_resolver.dart';
import '../datasources/local/account_operation_gate.dart';
import '../database/app_database.dart';
import '../database/daos/faces_dao.dart';
import '../database/daos/media_items_dao.dart';
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
  final Future<List<DetectedFace>> Function(String filePath)? _detectFaces;
  final Future<List<double>> Function(Uint8List croppedFaceBytes)? _embedFace;
  final Future<Directory> Function() _temporaryDirectory;
  final ThumbnailResolver _thumbnailResolver;
  final Future<String?> Function(String accountId) _accessTokenLoader;

  static const _uuid = Uuid();

  FaceRepositoryImpl({
    required this.faceDetectionService,
    required this.faceEmbeddingService,
    required this.faceClusteringService,
    required this.facesDao,
    required this.mediaItemsDao,
    required this.mediaRepository,
    required this.secureStorage,
    Future<List<DetectedFace>> Function(String filePath)? detectFaces,
    Future<List<double>> Function(Uint8List croppedFaceBytes)? embedFace,
    Future<Directory> Function()? temporaryDirectory,
    ThumbnailResolver? thumbnailResolver,
    Future<String?> Function(String accountId)? accessTokenLoader,
  }) : _detectFaces = detectFaces,
       _embedFace = embedFace,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _thumbnailResolver = thumbnailResolver ?? ThumbnailResolver(),
       _accessTokenLoader = accessTokenLoader ?? secureStorage.getAccessToken;

  @override
  Future<void> processMediaItem(
    String mediaItemId,
    Uint8List thumbnailBytes, {
    List<Uint8List> additionalFrames = const [],
    FaceProcessingContext? expectedSource,
  }) async {
    final tempFiles = <File>[];
    try {
      final source = await mediaItemsDao.getMediaItemById(mediaItemId);
      if (source == null || source.isDeleted) return;
      final context =
          expectedSource ??
          FaceProcessingContext(
            accountId: source.accountId,
            fileHash: source.fileHash,
            syncedAt: source.syncedAt,
            accountGeneration: AccountOperationGate.generationFor(
              source.accountId,
            ),
          );
      // A caller that captured a source before its download must never attach
      // those old bytes to a row that was relinked in the meantime.
      if (!_matchesContext(source, context)) return;
      final tempDir = await _temporaryDirectory();
      // Build the complete replacement before touching persisted faces. Any
      // crop/model failure keeps the previous result intact and retryable.
      final replacements = <FacesCompanion>[];
      final uniqueFrames = <Uint8List>[];
      final seenFrames = <String>{};
      for (final frame in [thumbnailBytes, ...additionalFrames]) {
        if (frame.isEmpty) continue;
        final fingerprint = base64Encode(frame);
        if (seenFrames.add(fingerprint)) uniqueFrames.add(frame);
      }

      for (final frame in uniqueFrames) {
        final tempFile = File('${tempDir.path}/face_detect_${_uuid.v4()}.jpg');
        tempFiles.add(tempFile);
        await tempFile.writeAsBytes(frame);
        final detectedFaces =
            await (_detectFaces?.call(tempFile.path) ??
                faceDetectionService.detectFacesFromFile(tempFile.path));

        for (final detected in detectedFaces) {
          final rect = detected.boundingBox;
          final faceSize = rect.width > rect.height ? rect.width : rect.height;

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
            frame,
            left: rect.left.toInt(),
            top: rect.top.toInt(),
            width: rect.width.toInt(),
            height: rect.height.toInt(),
            padding: AppConstants.facePaddingRatio,
            eyeAngleDegrees: detected.eyeRotationDegrees,
          );

          final embedding =
              await (_embedFace?.call(croppedBytes) ??
                  faceEmbeddingService.getEmbedding(croppedBytes));
          final embeddingBytes = FaceEmbeddingService.embeddingToBytes(
            embedding,
          );

          replacements.add(
            FacesCompanion.insert(
              id: _uuid.v4(),
              mediaItemId: mediaItemId,
              boundingBox: jsonEncode({
                'left': rect.left,
                'top': rect.top,
                'width': rect.width,
                'height': rect.height,
                // The crop is from the exact frame sent to detection.  It makes
                // offline representative portraits correct for videos and for
                // provider thumbnails whose dimensions changed after detection.
                'crop': base64Encode(croppedBytes),
              }),
              embedding: embeddingBytes,
            ),
          );
        }
      }

      // Commit the revision validation, face replacement, and processed flag
      // in one gated database transaction. Unlink retires first and drains
      // this gate before purging the account, so derived rows cannot appear
      // after local cleanup.
      await AccountOperationGate.runIfCurrent(
        context.accountId,
        context.accountGeneration,
        () => mediaItemsDao.transaction(() async {
          final current = await mediaItemsDao.getMediaItemById(mediaItemId);
          if (current == null || !_matchesContext(current, context)) {
            return;
          }
          await facesDao.replaceFacesForMedia(mediaItemId, replacements);
          await mediaItemsDao.markFacesProcessed(mediaItemId);
        }),
      );
    } catch (e) {
      AppLogger.error('Face processing failed for $mediaItemId', error: e);
      rethrow;
    } finally {
      for (final tempFile in tempFiles) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> runClustering() async {
    try {
      final snapshot = await facesDao.captureClusteringSnapshot();
      if (snapshot.faces.isEmpty) {
        await facesDao.pruneOrphanClusters();
        return;
      }

      // Convert DB face objects to FaceModel
      final faceModels = snapshot.faces
          .map(
            (f) => FaceModel(
              id: f.id,
              mediaItemId: f.mediaItemId,
              boundingBox: f.boundingBox,
              embedding: f.embedding,
              clusterId: f.clusterId,
              detectedAt: f.detectedAt,
            ),
          )
          .toList();

      // Load existing cluster centroids
      final existingClusters = snapshot.clusters;
      final existingCentroids = <String, List<double>>{};
      for (final cluster in existingClusters) {
        if (cluster.centroidEmbedding != null) {
          existingCentroids[cluster.id] = FaceEmbeddingService.bytesToEmbedding(
            cluster.centroidEmbedding!,
          );
        }
      }

      // Run clustering
      final workerResult = await faceClusteringService.clusterFacesInWorker(
        FaceClusteringWorkerInput.fromFaces(
          faceModels,
          existingCentroids: existingCentroids.isNotEmpty
              ? existingCentroids
              : null,
        ),
      );
      final result = workerResult.toClusterResult();

      final committed = await facesDao.replaceClusterStateIfSnapshotCurrent(
        snapshot: snapshot,
        assignments: {
          for (final assignment in result.assignments)
            assignment.faceId: assignment.clusterId,
        },
        centroids: result.clusterCentroids,
        counts: result.clusterCounts,
        representatives: result.clusterRepresentatives,
      );

      if (!committed) {
        AppLogger.info(
          'Clustering input changed while worker ran; skipping stale result',
        );
        return;
      }

      AppLogger.info(
        'Clustering complete: ${result.assignments.length} faces, '
        '${result.clusterCentroids.length} clusters',
      );
    } catch (e) {
      AppLogger.error('Clustering failed', error: e);
      rethrow;
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
      (clusters) =>
          clusters.map<FaceClusterEntity>(_mapClusterToEntity).toList(),
    );
  }

  @override
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId) async {
    final mediaIds = await facesDao.getMediaIdsForCluster(clusterId);
    return mediaRepository.getMediaItemsByIds(mediaIds);
  }

  @override
  Stream<List<MediaItemEntity>> watchMediaForCluster(String clusterId) =>
      facesDao
          .watchMediaIdsForCluster(clusterId)
          .asyncMap(mediaRepository.getMediaItemsByIds);

  @override
  Future<MediaItemEntity?> getRepresentativeMediaForCluster(
    String clusterId,
  ) async {
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
  Stream<MediaItemEntity?> watchRepresentativeMediaForCluster(
    String clusterId,
  ) => facesDao
      .watchRepresentativeRevision(clusterId)
      .asyncMap((_) => getRepresentativeMediaForCluster(clusterId));

  @override
  Future<Uint8List?> getRepresentativeFaceThumbnail(String clusterId) async {
    final cluster = await facesDao.getClusterById(clusterId);
    final representativeFaceId = cluster?.representativeFaceId;
    if (representativeFaceId == null || representativeFaceId.isEmpty) {
      return null;
    }

    final face = await facesDao.getFaceById(representativeFaceId);
    if (face == null) return null;

    final storedCrop = _parseStoredCrop(face.boundingBox);
    if (storedCrop != null) return storedCrop;

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
  Stream<Uint8List?> watchRepresentativeFaceThumbnail(String clusterId) =>
      facesDao
          .watchRepresentativeRevision(clusterId)
          .asyncMap((_) => getRepresentativeFaceThumbnail(clusterId));

  @override
  Future<void> renameCluster(String clusterId, String name) async {
    await facesDao.updateClusterLabel(clusterId, name);
  }

  @override
  Future<void> resetAllFaceData() async {
    await facesDao.deleteAllFacesAndClusters();
    await mediaItemsDao.resetAllFacesProcessed();
    AppLogger.info(
      'Reset all face data: cleared faces, clusters, and processing flags',
    );
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

  Uint8List? _parseStoredCrop(String jsonStr) {
    try {
      final crop = (jsonDecode(jsonStr) as Map<String, dynamic>)['crop'];
      if (crop is! String || crop.isEmpty) return null;
      return Uint8List.fromList(base64Decode(crop));
    } catch (_) {
      // Existing rows only contain coordinates and continue through the
      // backwards-compatible thumbnail crop path below.
      return null;
    }
  }

  bool _matchesContext(MediaItem source, FaceProcessingContext context) =>
      !source.isDeleted &&
      source.accountId == context.accountId &&
      source.fileHash == context.fileHash &&
      source.syncedAt == context.syncedAt;

  Future<Uint8List?> _downloadMediaThumbnail(MediaItemEntity media) async {
    // Older rows may not carry a source-frame crop. Their portrait fallback
    // still observes the same generation boundary as scanning/cache writes.
    final generation = AccountOperationGate.generationFor(media.accountId);
    final cacheKey =
        '${media.accountId}|${media.remoteId}|${media.fileHash ?? media.syncedAt.microsecondsSinceEpoch}';
    final cached = await _thumbnailResolver.readCached(
      cacheKey,
      accountId: media.accountId,
      accountGeneration: generation,
    );
    if (cached != null) return cached;
    if (!AccountOperationGate.isCurrent(media.accountId, generation)) {
      return null;
    }

    final token = await _accessTokenLoader(media.accountId);
    if (!AccountOperationGate.isCurrent(media.accountId, generation)) {
      return null;
    }
    if (token == null || token.isEmpty) return null;
    final headers = {'Authorization': 'Bearer $token'};

    final thumbnailUrl =
        media.thumbnailUrl ??
        ThumbnailResolver.constructThumbnailUrl(
          accountId: media.accountId,
          remoteId: media.remoteId,
          remotePath: media.remotePath,
        );
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) return null;

    return _thumbnailResolver.resolve(
      thumbnailUrl,
      headers,
      cacheKey: cacheKey,
      accountId: media.accountId,
      accountGeneration: generation,
    );
  }
}
