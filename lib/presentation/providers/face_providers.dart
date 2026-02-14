import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/local/ai_pipeline_orchestrator.dart';
import '../../data/datasources/local/face_clustering_service.dart';
import '../../data/datasources/local/face_detection_service.dart';
import '../../data/datasources/local/face_embedding_service.dart';
import '../../data/repositories/face_repository_impl.dart';
import '../../domain/entities/face_cluster.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/repositories/face_repository.dart';
import 'auth_providers.dart';
import 'database_providers.dart';
import 'media_providers.dart';

final faceDetectionServiceProvider = Provider<FaceDetectionService>((ref) {
  final service = FaceDetectionService();
  ref.onDispose(() => service.dispose());
  return service;
});

final faceEmbeddingServiceProvider = FutureProvider<FaceEmbeddingService>((ref) async {
  final service = FaceEmbeddingService();
  await service.initialize();
  ref.onDispose(() => service.dispose());
  return service;
});

final faceClusteringServiceProvider = Provider<FaceClusteringService>((ref) {
  return FaceClusteringService();
});

final faceRepositoryProvider = Provider<FaceRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final embeddingService = ref.watch(faceEmbeddingServiceProvider).value;
  if (embeddingService == null) {
    throw StateError('FaceEmbeddingService not yet initialized');
  }
  return FaceRepositoryImpl(
    faceDetectionService: ref.watch(faceDetectionServiceProvider),
    faceEmbeddingService: embeddingService,
    faceClusteringService: ref.watch(faceClusteringServiceProvider),
    facesDao: db.facesDao,
    mediaItemsDao: db.mediaItemsDao,
    mediaRepository: ref.watch(mediaRepositoryProvider),
  );
});

final aiPipelineProvider = Provider<AIPipelineOrchestrator>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AIPipelineOrchestrator(
    faceRepository: ref.watch(faceRepositoryProvider),
    mediaItemsDao: db.mediaItemsDao,
    accountsDao: db.accountsDao,
    providers: ref.watch(cloudProvidersProvider),
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final peopleProvider = StreamProvider<List<FaceClusterEntity>>((ref) {
  try {
    return ref.watch(faceRepositoryProvider).watchClusters();
  } catch (_) {
    return const Stream.empty();
  }
});

final mediaForPersonProvider = FutureProvider.family<List<MediaItemEntity>, String>((ref, clusterId) {
  try {
    return ref.watch(faceRepositoryProvider).getMediaForCluster(clusterId);
  } catch (_) {
    return Future.value([]);
  }
});
