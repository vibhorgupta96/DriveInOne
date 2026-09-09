import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:drive_in_one/core/enums/media_type.dart';
import 'package:drive_in_one/data/database/app_database.dart';
import 'package:drive_in_one/data/database/tables/accounts_table.dart';
import 'package:drive_in_one/data/database/tables/media_items_table.dart';
import 'package:drive_in_one/data/datasources/local/face_clustering_service.dart';
import 'package:drive_in_one/data/datasources/local/account_operation_gate.dart';
import 'package:drive_in_one/data/datasources/local/ai_pipeline_orchestrator.dart';
import 'package:drive_in_one/data/datasources/local/face_detection_service.dart';
import 'package:drive_in_one/data/datasources/local/face_embedding_service.dart';
import 'package:drive_in_one/data/datasources/local/secure_storage_source.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:drive_in_one/data/repositories/face_repository_impl.dart';
import 'package:drive_in_one/data/repositories/media_repository_impl.dart';
import 'package:drive_in_one/domain/repositories/face_repository.dart';
import 'package:drive_in_one/domain/entities/face_cluster.dart';
import 'package:drive_in_one/domain/entities/media_item.dart';
import 'package:drive_in_one/presentation/providers/face_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await database.accountsDao.insertAccount(
      AccountsCompanion.insert(
        id: 'dropbox-face-test',
        providerType: ProviderTypeEnum.dropbox,
        email: 'faces@example.com',
      ),
    );
    await database.accountsDao.insertAccount(
      AccountsCompanion.insert(
        id: 'pipeline-account',
        providerType: ProviderTypeEnum.dropbox,
        email: 'pipeline@example.com',
      ),
    );
    await database.accountsDao.insertAccount(
      AccountsCompanion.insert(
        id: 'onedrive|pipeline-account',
        providerType: ProviderTypeEnum.onedrive,
        email: 'onedrive@example.com',
      ),
    );
  });

  tearDown(() => database.close());

  Future<void> insertMedia({
    String hash = 'v1',
    String accountId = 'dropbox-face-test',
    String? fullSizeUrl,
    String? thumbnailUrl,
    int? durationSeconds,
  }) => database.mediaItemsDao.upsertMediaItem(
    MediaItemsCompanion.insert(
      id: 'media',
      accountId: accountId,
      remoteId: 'remote-media',
      fileName: 'clip.mp4',
      mimeType: 'video/mp4',
      mediaType: MediaTypeEnum.video,
      fileHash: Value(hash),
      fullSizeUrl: Value(fullSizeUrl),
      thumbnailUrl: Value(thumbnailUrl),
      durationSeconds: Value(durationSeconds),
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );

  FaceRepositoryImpl repository({
    Future<String?> Function(String accountId)? accessTokenLoader,
  }) => FaceRepositoryImpl(
    // These real services are never reached: deterministic callbacks keep the
    // test independent of native ML Kit/TFLite plugins.
    faceDetectionService: FaceDetectionService(),
    faceEmbeddingService: FaceEmbeddingService(),
    faceClusteringService: FaceClusteringService(),
    facesDao: database.facesDao,
    mediaItemsDao: database.mediaItemsDao,
    mediaRepository: MediaRepositoryImpl(mediaItemsDao: database.mediaItemsDao),
    secureStorage: SecureStorageSource(),
    detectFaces: (_) async => const [
      DetectedFace(boundingBox: Rect.fromLTWH(20, 20, 80, 80)),
    ],
    embedFace: (_) async => const [1, 0, 0],
    temporaryDirectory: () async => Directory.systemTemp,
    accessTokenLoader: accessTokenLoader,
  );

  Uint8List frame(int color) {
    final image = img.Image(width: 160, height: 160);
    img.fill(image, color: img.ColorRgb8(color, 10, 20));
    return Uint8List.fromList(img.encodePng(image));
  }

  test(
    'combines all distinct video frames in one replacement and retries cleanly',
    () async {
      await insertMedia();
      final item = (await database.mediaItemsDao.getMediaItemById('media'))!;
      final context = FaceProcessingContext(
        accountId: item.accountId,
        fileHash: item.fileHash,
        syncedAt: item.syncedAt,
        accountGeneration: AccountOperationGate.generationFor(item.accountId),
      );

      await repository().processMediaItem(
        item.id,
        frame(20),
        additionalFrames: [frame(90), frame(20)],
        expectedSource: context,
      );
      expect(await database.facesDao.getFacesByMedia(item.id), hasLength(2));

      await repository().processMediaItem(
        item.id,
        frame(140),
        expectedSource: context,
      );
      expect(await database.facesDao.getFacesByMedia(item.id), hasLength(1));
      expect(
        (await database.mediaItemsDao.getMediaItemById(
          item.id,
        ))!.facesProcessed,
        isTrue,
      );
    },
  );

  test(
    'returns the persisted detection-frame crop for a representative',
    () async {
      await insertMedia();
      final item = (await database.mediaItemsDao.getMediaItemById('media'))!;
      await repository().processMediaItem(
        item.id,
        frame(70),
        expectedSource: FaceProcessingContext(
          accountId: item.accountId,
          fileHash: item.fileHash,
          syncedAt: item.syncedAt,
          accountGeneration: AccountOperationGate.generationFor(item.accountId),
        ),
      );
      final face = (await database.facesDao.getFacesByMedia(item.id)).single;
      await database.facesDao.insertCluster(
        FaceClustersCompanion.insert(
          id: 'person',
          representativeFaceId: Value(face.id),
          faceCount: const Value(1),
        ),
      );
      await database.facesDao.updateFaceCluster(face.id, 'person');

      final portrait = await repository().getRepresentativeFaceThumbnail(
        'person',
      );
      final stored = jsonDecode(face.boundingBox) as Map<String, dynamic>;
      expect(
        portrait,
        Uint8List.fromList(base64Decode(stored['crop'] as String)),
      );
    },
  );

  test('discards a scan downloaded for an old media revision', () async {
    await insertMedia(hash: 'old');
    final old = (await database.mediaItemsDao.getMediaItemById('media'))!;
    await insertMedia(hash: 'new');

    await repository().processMediaItem(
      old.id,
      frame(30),
      expectedSource: FaceProcessingContext(
        accountId: old.accountId,
        fileHash: old.fileHash,
        syncedAt: old.syncedAt,
        accountGeneration: AccountOperationGate.generationFor(old.accountId),
      ),
    );

    expect(await database.facesDao.getFacesByMedia(old.id), isEmpty);
    expect(
      (await database.mediaItemsDao.getMediaItemById(old.id))!.facesProcessed,
      isFalse,
    );
  });

  test('discards a scan after its account generation was retired', () async {
    await insertMedia();
    final item = (await database.mediaItemsDao.getMediaItemById('media'))!;
    final generation = AccountOperationGate.generationFor(item.accountId);
    AccountOperationGate.retire(item.accountId);

    await repository().processMediaItem(
      item.id,
      frame(30),
      expectedSource: FaceProcessingContext(
        accountId: item.accountId,
        fileHash: item.fileHash,
        syncedAt: item.syncedAt,
        accountGeneration: generation,
      ),
    );

    expect(await database.facesDao.getFacesByMedia(item.id), isEmpty);
    expect(
      (await database.mediaItemsDao.getMediaItemById(item.id))!.facesProcessed,
      isFalse,
    );
  });

  test(
    'orchestrator sends all distinct sampled frames to one face replacement',
    () async {
      await insertMedia(
        accountId: 'pipeline-account',
        fullSizeUrl: 'https://video.example/current.mp4',
        durationSeconds: 2,
      );
      final first = frame(20);
      final second = frame(90);
      final pipeline = AIPipelineOrchestrator(
        faceRepository: repository(),
        mediaItemsDao: database.mediaItemsDao,
        accountsDao: database.accountsDao,
        secureStorage: SecureStorageSource(),
        accessTokenLoader: (_) async => 'token',
        videoFrameExtractor:
            ({required timeMs, required videoUrl, required headers}) async =>
                timeMs < 1000 ? first : second,
      );

      await pipeline.processNewMedia(batchSize: 1);

      final faces = await database.facesDao.getFacesByMedia('media');
      expect(faces, hasLength(2));
      expect(
        (await database.mediaItemsDao.getMediaItemById(
          'media',
        ))!.facesProcessed,
        isTrue,
      );
    },
  );

  test(
    'orchestrator prefers a fresh OneDrive stream URL to stored URL',
    () async {
      await insertMedia(
        accountId: 'onedrive|pipeline-account',
        fullSizeUrl: 'https://expired.example/old.mp4',
        thumbnailUrl: 'https://poster.example/image.jpg',
        durationSeconds: 1,
      );
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: {
                '@microsoft.graph.downloadUrl': 'https://fresh.example/new.mp4',
              },
            ),
          ),
        ),
      );
      final requestedUrls = <String>[];
      final pipeline = AIPipelineOrchestrator(
        faceRepository: repository(),
        mediaItemsDao: database.mediaItemsDao,
        accountsDao: database.accountsDao,
        secureStorage: SecureStorageSource(),
        dio: dio,
        accessTokenLoader: (_) async => 'token',
        videoFrameExtractor:
            ({required timeMs, required videoUrl, required headers}) async {
              requestedUrls.add(videoUrl);
              return frame(40);
            },
      );

      await pipeline.processNewMedia(batchSize: 1);

      expect(requestedUrls, isNotEmpty);
      expect(requestedUrls, everyElement('https://fresh.example/new.mp4'));
    },
  );

  test(
    'orchestrator falls back to a provider poster when frame extraction fails',
    () async {
      await insertMedia(
        hash: 'poster-fallback',
        accountId: 'pipeline-account',
        fullSizeUrl: 'https://video.example/current.mp4',
        thumbnailUrl: 'https://poster.example/image.jpg',
      );
      final posterDio = Dio();
      posterDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(requestOptions: options, data: frame(120)),
          ),
        ),
      );
      final pipeline = AIPipelineOrchestrator(
        faceRepository: repository(),
        mediaItemsDao: database.mediaItemsDao,
        accountsDao: database.accountsDao,
        secureStorage: SecureStorageSource(),
        thumbnailResolver: ThumbnailResolver(
          dio: posterDio,
          cacheRoot: () async => Directory.systemTemp,
        ),
        accessTokenLoader: (_) async => 'token',
        videoFrameExtractor:
            ({required timeMs, required videoUrl, required headers}) =>
                Future<Uint8List?>.error(StateError('codec unavailable')),
      );

      await pipeline.processNewMedia(batchSize: 1);

      expect(await database.facesDao.getFacesByMedia('media'), hasLength(1));
      expect(
        (await database.mediaItemsDao.getMediaItemById(
          'media',
        ))!.facesProcessed,
        isTrue,
      );
    },
  );

  test(
    'orchestrator skips a token read retired during auth preparation',
    () async {
      await insertMedia(
        accountId: 'pipeline-account',
        fullSizeUrl: 'https://video.example/current.mp4',
      );
      final tokenReadStarted = Completer<void>();
      final delayedToken = Completer<String?>();
      final pipeline = AIPipelineOrchestrator(
        faceRepository: repository(),
        mediaItemsDao: database.mediaItemsDao,
        accountsDao: database.accountsDao,
        secureStorage: SecureStorageSource(),
        accessTokenLoader: (accountId) {
          if (accountId != 'pipeline-account') return Future.value('token');
          tokenReadStarted.complete();
          return delayedToken.future;
        },
        videoFrameExtractor:
            ({required timeMs, required videoUrl, required headers}) async =>
                frame(60),
      );

      final run = pipeline.processNewMedia(batchSize: 1);
      await tokenReadStarted.future;
      AccountOperationGate.retire('pipeline-account');
      delayedToken.complete('token-after-unlink');
      await run;

      expect(await database.facesDao.getFacesByMedia('media'), isEmpty);
      expect(
        (await database.mediaItemsDao.getMediaItemById(
          'media',
        ))!.facesProcessed,
        isFalse,
      );
    },
  );

  test(
    'orchestrator discards a frame that completes after account retirement',
    () async {
      await insertMedia(
        accountId: 'pipeline-account',
        fullSizeUrl: 'https://video.example/current.mp4',
      );
      final frameStarted = Completer<void>();
      final delayedFrame = Completer<Uint8List?>();
      final pipeline = AIPipelineOrchestrator(
        faceRepository: repository(),
        mediaItemsDao: database.mediaItemsDao,
        accountsDao: database.accountsDao,
        secureStorage: SecureStorageSource(),
        accessTokenLoader: (_) async => 'token',
        videoFrameExtractor:
            ({required timeMs, required videoUrl, required headers}) {
              frameStarted.complete();
              return delayedFrame.future;
            },
      );

      final run = pipeline.processNewMedia(batchSize: 1);
      await frameStarted.future;
      AccountOperationGate.retire('pipeline-account');
      delayedFrame.complete(frame(80));
      await run;

      expect(await database.facesDao.getFacesByMedia('media'), isEmpty);
      expect(
        (await database.mediaItemsDao.getMediaItemById(
          'media',
        ))!.facesProcessed,
        isFalse,
      );
    },
  );

  test(
    'legacy portrait fallback rejects a token read retired by unlink',
    () async {
      await insertMedia(accountId: 'pipeline-account');
      await database.facesDao.insertFace(
        FacesCompanion.insert(
          id: 'legacy-face',
          mediaItemId: 'media',
          boundingBox: '{"left": 0, "top": 0, "width": 80, "height": 80}',
          embedding: Uint8List(12),
          clusterId: const Value('legacy-person'),
        ),
      );
      await database.facesDao.insertCluster(
        FaceClustersCompanion.insert(
          id: 'legacy-person',
          representativeFaceId: const Value('legacy-face'),
          faceCount: const Value(1),
        ),
      );
      final tokenReadStarted = Completer<void>();
      final delayedToken = Completer<String?>();
      final portrait = repository(
        accessTokenLoader: (_) {
          tokenReadStarted.complete();
          return delayedToken.future;
        },
      ).getRepresentativeFaceThumbnail('legacy-person');

      await tokenReadStarted.future;
      AccountOperationGate.retire('pipeline-account');
      delayedToken.complete('stale-token');

      expect(await portrait, isNull);
    },
  );

  test('representative provider emits a same-id media revision', () async {
    final fake = _RepresentativeRepository();
    final container = ProviderContainer(
      overrides: [faceRepositoryProvider.overrideWith((_) async => fake)],
    );
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });
    final revisions = <MediaItemEntity>[];
    final subscription = container.listen(
      representativeMediaProvider('person'),
      (_, next) {
        final item = next.value;
        if (item != null) revisions.add(item);
      },
    );
    addTearDown(subscription.close);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final original = _representativeMedia(
      hash: 'old',
      thumbnailUrl: 'https://example.test/old.jpg',
    );
    final revised = _representativeMedia(
      hash: 'new',
      thumbnailUrl: 'https://example.test/new.jpg',
    );
    fake.emit(original);
    await Future<void>.delayed(Duration.zero);
    fake.emit(revised);
    await Future<void>.delayed(Duration.zero);

    expect(revisions, [original, revised]);
  });
}

MediaItemEntity _representativeMedia({
  required String hash,
  required String thumbnailUrl,
}) => MediaItemEntity(
  id: 'same-media-id',
  accountId: 'dropbox-face-test',
  remoteId: 'remote-media',
  fileName: 'clip.mp4',
  mimeType: 'video/mp4',
  mediaType: MediaType.video,
  thumbnailUrl: thumbnailUrl,
  fileHash: hash,
  timestamp: DateTime.utc(2026, 1, 1),
  syncedAt: DateTime.utc(2026, 1, hash == 'old' ? 1 : 2),
);

class _RepresentativeRepository implements FaceRepository {
  final _media = StreamController<MediaItemEntity?>.broadcast();

  void emit(MediaItemEntity media) => _media.add(media);
  void dispose() => _media.close();

  @override
  Future<void> processMediaItem(
    String mediaItemId,
    Uint8List thumbnailBytes, {
    List<Uint8List> additionalFrames = const [],
    FaceProcessingContext? expectedSource,
  }) async {}

  @override
  Future<List<FaceClusterEntity>> getClusters() async => const [];

  @override
  Future<Map<String, int>> getDiagnosticCounts() async => const {};

  @override
  Future<List<MediaItemEntity>> getMediaForCluster(String clusterId) async =>
      const [];

  @override
  Future<MediaItemEntity?> getRepresentativeMediaForCluster(
    String clusterId,
  ) async => null;

  @override
  Future<Uint8List?> getRepresentativeFaceThumbnail(String clusterId) async =>
      null;

  @override
  Future<void> renameCluster(String clusterId, String name) async {}

  @override
  Future<void> resetAllFaceData() async {}

  @override
  Future<void> runClustering() async {}

  @override
  Stream<List<FaceClusterEntity>> watchClusters() => const Stream.empty();

  @override
  Stream<List<MediaItemEntity>> watchMediaForCluster(String clusterId) =>
      const Stream.empty();

  @override
  Stream<MediaItemEntity?> watchRepresentativeMediaForCluster(
    String clusterId,
  ) => _media.stream;

  @override
  Stream<Uint8List?> watchRepresentativeFaceThumbnail(String clusterId) =>
      const Stream.empty();
}
