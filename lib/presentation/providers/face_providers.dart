import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/foreground_service_helper.dart';
import '../../core/utils/logger.dart';
import '../../data/datasources/local/ai_pipeline_orchestrator.dart';
export '../../data/datasources/local/ai_pipeline_orchestrator.dart'
    show FacePipelineException, PipelineProgress, TokenExpiredException;
import '../../data/datasources/local/face_clustering_service.dart';
import '../../data/datasources/local/face_detection_service.dart';
import '../../data/datasources/local/face_embedding_service.dart';
import '../../data/repositories/face_repository_impl.dart';
import '../../domain/entities/face_cluster.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/face_repository.dart';
import 'database_providers.dart';
import 'media_providers.dart';
import 'sync_providers.dart';

final faceDetectionServiceProvider = Provider<FaceDetectionService>((ref) {
  final service = FaceDetectionService();
  ref.onDispose(() => service.dispose());
  return service;
});

final faceEmbeddingServiceProvider =
    FutureProvider<FaceEmbeddingService>((ref) async {
  AppLogger.info('Loading MobileFaceNet model...');
  final service = FaceEmbeddingService();
  await service.initialize();
  AppLogger.info('MobileFaceNet model loaded');
  ref.onDispose(() => service.dispose());
  return service;
});

final faceClusteringServiceProvider = Provider<FaceClusteringService>((ref) {
  return FaceClusteringService();
});

final faceRepositoryProvider = FutureProvider<FaceRepository>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final embeddingService = await ref.watch(faceEmbeddingServiceProvider.future);
  return FaceRepositoryImpl(
    faceDetectionService: ref.watch(faceDetectionServiceProvider),
    faceEmbeddingService: embeddingService,
    faceClusteringService: ref.watch(faceClusteringServiceProvider),
    facesDao: db.facesDao,
    mediaItemsDao: db.mediaItemsDao,
    mediaRepository: ref.watch(mediaRepositoryProvider),
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final aiPipelineProvider = FutureProvider<AIPipelineOrchestrator>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final faceRepo = await ref.watch(faceRepositoryProvider.future);
  AppLogger.info('AI pipeline initialized');
  return AIPipelineOrchestrator(
    faceRepository: faceRepo,
    mediaItemsDao: db.mediaItemsDao,
    accountsDao: db.accountsDao,
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final faceScanNotifierProvider =
    NotifierProvider<FaceScanNotifier, AsyncValue<void>>(() {
  return FaceScanNotifier();
});

class FaceScanNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() {
    return const AsyncData(null);
  }

  Future<void> startScan() async {
    try {
      state = const AsyncLoading();
      try {
        await ForegroundServiceHelper.start(
          serviceId: 501,
          channelId: 'driveinone_face_scan',
          channelName: 'Face Scan Service',
          channelDescription: 'Scanning faces in your media library',
          notificationTitle: 'DriveInOne',
          notificationText: 'Scanning faces in background...',
        );
      } catch (_) {}

      AppLogger.info('FaceScanNotifier: refreshing tokens (silent only)...');
      await ref.read(syncRepositoryProvider).refreshAllTokens(silentOnly: true);

      final faceRepo = await ref.read(faceRepositoryProvider.future);
      final counts = await faceRepo.getDiagnosticCounts();
      AppLogger.info('FaceScanNotifier: DB state — '
          '${counts['totalMedia']} media, ${counts['processedMedia']} processed, '
          '${counts['unprocessedMedia']} unprocessed, '
          '${counts['faces']} faces, ${counts['clusters']} clusters, '
          '${counts['unclusteredFaces']} unclustered');

      final pipeline = await ref.read(aiPipelineProvider.future);
      if (pipeline.isRunning) {
        AppLogger.info(
          'FaceScanNotifier: pipeline already running; awaiting active scan',
        );
      }
      AppLogger.info('FaceScanNotifier: starting processNewMedia');
      await pipeline.processNewMedia();
      AppLogger.info('FaceScanNotifier: processNewMedia complete');
      state = const AsyncData(null);
    } on TokenExpiredException catch (e, st) {
      AppLogger.error('FaceScanNotifier: scan failed due to token expiration',
          error: e, stackTrace: st);
      state = AsyncError(e, st);
    } catch (e, st) {
      AppLogger.error('FaceScanNotifier: scan failed',
          error: e, stackTrace: st);
      state = AsyncError(e, st);
    } finally {
      try {
        await ForegroundServiceHelper.stop();
      } catch (_) {}
    }
  }

  Future<void> resetAndRescan() async {
    try {
      state = const AsyncLoading();
      AppLogger.info('FaceScanNotifier: resetting all face data...');
      final faceRepo = await ref.read(faceRepositoryProvider.future);
      await faceRepo.resetAllFaceData();
      ref.invalidate(peopleProvider);
      AppLogger.info(
          'FaceScanNotifier: reset complete, starting fresh scan...');
      await startScan();
    } catch (e, st) {
      AppLogger.error('FaceScanNotifier: reset & rescan failed',
          error: e, stackTrace: st);
      state = AsyncError(e, st);
    }
  }
}

final peopleProvider = StreamProvider<List<FaceClusterEntity>>((ref) async* {
  final faceRepo = await ref.watch(faceRepositoryProvider.future);
  yield* faceRepo.watchClusters();
});

final pipelineProgressProvider = StreamProvider<PipelineProgress>((ref) async* {
  final pipeline = await ref.watch(aiPipelineProvider.future);
  yield* pipeline.progressStream;
});

final mediaForPersonProvider =
    FutureProvider.family<List<MediaItemEntity>, String>(
        (ref, clusterId) async {
  final faceRepo = await ref.watch(faceRepositoryProvider.future);
  return faceRepo.getMediaForCluster(clusterId);
});

final representativeMediaProvider =
    FutureProvider.family<MediaItemEntity?, String>((ref, clusterId) async {
  final faceRepo = await ref.watch(faceRepositoryProvider.future);
  return faceRepo.getRepresentativeMediaForCluster(clusterId);
});

final representativeFaceThumbnailProvider =
    FutureProvider.family<Uint8List?, String>((ref, clusterId) async {
  final faceRepo = await ref.watch(faceRepositoryProvider.future);
  return faceRepo.getRepresentativeFaceThumbnail(clusterId);
});
