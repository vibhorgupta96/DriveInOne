import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/constants/provider_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/repositories/face_repository.dart';
import '../../database/app_database.dart';
import '../../database/daos/accounts_dao.dart';
import '../../database/daos/media_items_dao.dart';
import '../../database/tables/media_items_table.dart';
import '../../datasources/local/secure_storage_source.dart';
import 'thumbnail_resolver.dart';
import 'account_operation_gate.dart';

class TokenExpiredException implements Exception {
  final String message;
  const TokenExpiredException(this.message);
  @override
  String toString() => message;
}

class FacePipelineException implements Exception {
  final Map<String, Object> failures;

  const FacePipelineException(this.failures);

  @override
  String toString() =>
      'Face scanning failed for ${failures.length} media item(s). '
      'They were left unprocessed and will be retried.';
}

class PipelineProgress {
  final int processed;
  final int total;
  final bool isRunning;

  const PipelineProgress({
    required this.processed,
    required this.total,
    required this.isRunning,
  });

  double get fraction => total > 0 ? processed / total : 0;

  static const idle = PipelineProgress(
    processed: 0,
    total: 0,
    isRunning: false,
  );
}

class _AuthHeaders {
  const _AuthHeaders({required this.headers, required this.accountGeneration});

  final Map<String, String> headers;
  final int accountGeneration;
}

typedef VideoFrameExtractor =
    Future<Uint8List?> Function({
      required String videoUrl,
      required int timeMs,
      required Map<String, String> headers,
    });

class AIPipelineOrchestrator {
  final FaceRepository faceRepository;
  final MediaItemsDao mediaItemsDao;
  final AccountsDao accountsDao;
  final SecureStorageSource secureStorage;
  final Dio _dio;
  final ThumbnailResolver _thumbnailResolver;
  final Future<String?> Function(String accountId) _accessTokenLoader;
  final VideoFrameExtractor? _videoFrameExtractor;

  Future<void>? _activeRun;
  bool get isRunning => _activeRun != null;

  final _progressController = StreamController<PipelineProgress>.broadcast();
  Stream<PipelineProgress> get progressStream => _progressController.stream;

  AIPipelineOrchestrator({
    required this.faceRepository,
    required this.mediaItemsDao,
    required this.accountsDao,
    required this.secureStorage,
    Dio? dio,
    ThumbnailResolver? thumbnailResolver,
    Future<String?> Function(String accountId)? accessTokenLoader,
    VideoFrameExtractor? videoFrameExtractor,
  }) : _dio = dio ?? Dio(),
       _thumbnailResolver = thumbnailResolver ?? ThumbnailResolver(),
       _accessTokenLoader = accessTokenLoader ?? secureStorage.getAccessToken,
       _videoFrameExtractor = videoFrameExtractor;

  final Map<String, _AuthHeaders> _authHeadersCache = {};
  final Set<String> _expiredAccounts = {};
  bool _videoThumbnailPluginAvailable = true;

  /// Loads stored tokens for all linked accounts.
  /// Never calls any auth SDK — tokens are refreshed during user-initiated sync.
  Future<void> _prepareAuthHeaders() async {
    _authHeadersCache.clear();
    _expiredAccounts.clear();
    final accounts = await accountsDao.getAllAccounts();
    for (final account in accounts) {
      try {
        // Capture before the asynchronous secure-storage read. An unlink or
        // relink during that await must not make this old run adopt the new
        // account generation and credentials.
        final accountGeneration = AccountOperationGate.generationFor(
          account.id,
        );
        final accessToken = await _accessTokenLoader(account.id);
        if (!AccountOperationGate.isCurrent(account.id, accountGeneration)) {
          AppLogger.info(
            'Face pipeline: account ${account.id} retired while loading token',
          );
          continue;
        }
        if (accessToken == null || accessToken.isEmpty) {
          _expiredAccounts.add(account.id);
          AppLogger.error(
            'Face pipeline: no stored token for ${account.id}, skipping',
          );
          continue;
        }

        _authHeadersCache[account.id] = _AuthHeaders(
          headers: {'Authorization': 'Bearer $accessToken'},
          accountGeneration: accountGeneration,
        );
        AppLogger.info('Face pipeline: using stored token for ${account.id}');
      } catch (e) {
        _expiredAccounts.add(account.id);
        AppLogger.error(
          'Face pipeline: failed to load token for ${account.id}',
          error: e,
        );
      }
    }

    if (_authHeadersCache.isEmpty) {
      throw const TokenExpiredException(
        'No auth tokens available. Please sync your accounts from Settings first.',
      );
    }
  }

  /// Processes unscanned media items in batches.
  /// Throws [TokenExpiredException] if stored tokens are expired/missing.
  Future<void> processNewMedia({int batchSize = AppConstants.faceBatchSize}) {
    final activeRun = _activeRun;
    if (activeRun != null) return activeRun;
    if (batchSize <= 0) {
      return Future.error(ArgumentError.value(batchSize, 'batchSize'));
    }

    final run = _processNewMedia(batchSize);
    _activeRun = run;
    return run.whenComplete(() {
      if (identical(_activeRun, run)) _activeRun = null;
    });
  }

  Future<void> _processNewMedia(int batchSize) async {
    try {
      final totalMedia = await mediaItemsDao.getMediaCount();
      final alreadyProcessed = await mediaItemsDao.getProcessedFacesCount();
      final allUnprocessed = await mediaItemsDao.getMediaItemsWithoutFaces(
        10000,
      );
      final total = totalMedia - alreadyProcessed;
      AppLogger.info(
        'Face pipeline: $total unprocessed out of $totalMedia total media items',
      );

      if (total > 0) {
        final withThumb = allUnprocessed
            .where((i) => i.thumbnailUrl != null && i.thumbnailUrl!.isNotEmpty)
            .length;
        final constructable = allUnprocessed
            .where(
              (i) =>
                  (i.thumbnailUrl == null || i.thumbnailUrl!.isEmpty) &&
                  _constructThumbnailUrl(i) != null,
            )
            .length;
        AppLogger.info(
          'Face pipeline: $withThumb have thumbnailUrl, $constructable can construct URL, '
          '${total - withThumb - constructable} have no thumbnail source',
        );
        await _prepareAuthHeaders();

        var completed = 0;
        final attemptedIds = <String>{};
        final failures = <String, Object>{};

        AppLogger.info('Face pipeline: starting, $total items to process');
        _progressController.add(
          PipelineProgress(processed: 0, total: total, isRunning: true),
        );

        while (true) {
          // Previously failed rows remain unprocessed at the head of this
          // query. Expand the window by the number already attempted so they
          // cannot hide every later media item in this run.
          final items = await mediaItemsDao.getMediaItemsWithoutFaces(
            batchSize + attemptedIds.length,
          );
          if (items.isEmpty) break;

          final toProcess = items
              .where((item) => !attemptedIds.contains(item.id))
              .toList();
          if (toProcess.isEmpty) break;

          for (final item in toProcess) {
            attemptedIds.add(item.id);
            if (_expiredAccounts.contains(item.accountId)) {
              failures[item.id] = TokenExpiredException(
                'No usable token for account ${item.accountId}',
              );
              _progressController.add(
                PipelineProgress(
                  processed: attemptedIds.length,
                  total: total,
                  isRunning: true,
                ),
              );
              continue;
            }

            final auth = _authHeadersCache[item.accountId];
            if (auth == null ||
                !AccountOperationGate.isCurrent(
                  item.accountId,
                  auth.accountGeneration,
                )) {
              // This run was prepared for a retired account generation. Do
              // not borrow the generation of a newly linked account.
              _progressController.add(
                PipelineProgress(
                  processed: attemptedIds.length,
                  total: total,
                  isRunning: true,
                ),
              );
              continue;
            }

            try {
              // Capture before network work; sync/unlink may replace this row
              // while a provider thumbnail or a video frame is downloading.
              final expectedSource = FaceProcessingContext(
                accountId: item.accountId,
                fileHash: item.fileHash,
                syncedAt: item.syncedAt,
                accountGeneration: auth.accountGeneration,
              );
              final frames = await _downloadFrames(
                item,
                accountGeneration: expectedSource.accountGeneration,
              );
              if (frames.isEmpty) {
                // This is reserved for a permanent, provider-confirmed lack of
                // any thumbnail source. Authentication and transport failures
                // throw and therefore remain retryable.
                await _markFacesProcessedIfCurrent(item.id, expectedSource);
              } else {
                await faceRepository.processMediaItem(
                  item.id,
                  frames.first,
                  additionalFrames: frames.skip(1).toList(growable: false),
                  expectedSource: expectedSource,
                );
              }
              completed++;
            } on TokenExpiredException catch (e) {
              _expiredAccounts.add(item.accountId);
              failures[item.id] = e;
              AppLogger.error(
                'Authentication unavailable for media item ${item.id}',
                error: e,
              );
            } catch (e) {
              AppLogger.error(
                'Failed to process media item ${item.id}',
                error: e,
              );
              failures[item.id] = e;
            }
            _progressController.add(
              PipelineProgress(
                processed: attemptedIds.length,
                total: total,
                isRunning: true,
              ),
            );
          }
        }

        // Cluster once after all independently processable media has been
        // attempted. Clustering errors are logged by the repository and must
        // propagate to this caller.
        await faceRepository.runClustering();

        if (_expiredAccounts.isNotEmpty) {
          AppLogger.info(
            'Face pipeline: tokens expired for accounts: '
            '${_expiredAccounts.join(', ')}. Sync those accounts to process remaining items.',
          );
        }
        AppLogger.info(
          'Face pipeline: complete, processed $completed items, '
          '${failures.length} skipped due to errors',
        );

        if (_expiredAccounts.isNotEmpty) {
          throw TokenExpiredException(
            'Authentication is unavailable for ${_expiredAccounts.length} '
            'account(s). Sync those accounts and retry face scanning.',
          );
        }
        if (failures.isNotEmpty) {
          throw FacePipelineException(Map.unmodifiable(failures));
        }
      } else {
        AppLogger.info('Face pipeline: no unprocessed media items');
        await faceRepository.runClustering();
      }
    } catch (e) {
      AppLogger.error('Face pipeline failed', error: e);
      rethrow;
    } finally {
      _authHeadersCache.clear();
      _expiredAccounts.clear();
      _progressController.add(PipelineProgress.idle);
    }
  }

  /// Constructs a thumbnail URL for items that were synced before providers
  /// started persisting stable thumbnail URL patterns.
  String? _constructThumbnailUrl(MediaItem item) =>
      ThumbnailResolver.constructThumbnailUrl(
        accountId: item.accountId,
        remoteId: item.remoteId,
        remotePath: item.remotePath,
      );

  /// Prefers all distinct sampled video frames. A provider poster is only a
  /// fallback when the video plugin is unavailable or produces no frame.
  Future<List<Uint8List>> _downloadFrames(
    MediaItem item, {
    required int accountGeneration,
  }) async {
    final auth = _authHeadersCache[item.accountId];
    if (auth == null || auth.accountGeneration != accountGeneration) {
      _expiredAccounts.add(item.accountId);
      throw TokenExpiredException(
        'No stored access token for account ${item.accountId}',
      );
    }
    if (!AccountOperationGate.isCurrent(item.accountId, accountGeneration)) {
      return const [];
    }
    final headers = auth.headers;
    Object? extractionError;
    StackTrace? extractionStackTrace;

    Future<List<Uint8List>> extractFrames() async {
      try {
        return await _extractVideoFrames(
          item,
          headers,
          accountGeneration: accountGeneration,
        );
      } catch (error, stackTrace) {
        extractionError ??= error;
        extractionStackTrace ??= stackTrace;
        return const [];
      }
    }

    var thumbnailUrl = item.thumbnailUrl;
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
      // For videos, fall back to extracting a frame from stream URL when
      // providers don't expose thumbnails in metadata.
      if (item.mediaType == MediaTypeEnum.video) {
        final frames = await extractFrames();
        if (frames.isNotEmpty) return frames;
      }
      thumbnailUrl = _constructThumbnailUrl(item);
      if (thumbnailUrl == null) {
        if (extractionError != null) {
          Error.throwWithStackTrace(extractionError!, extractionStackTrace!);
        }
        return const [];
      }
    }

    if (item.mediaType == MediaTypeEnum.video) {
      final frames = await extractFrames();
      if (frames.isNotEmpty) return frames;
    }

    // Convert stale googleusercontent.com URLs to the stable gdrive:// pattern
    // so we always fetch a fresh thumbnail link from the API.
    if (thumbnailUrl.contains('googleusercontent.com') &&
        item.accountId.startsWith('google|')) {
      thumbnailUrl = 'gdrive://thumb/${item.remoteId}';
    }

    try {
      final bytes = await _thumbnailResolver.resolve(
        thumbnailUrl,
        headers,
        cacheKey:
            '${item.accountId}|${item.remoteId}|${item.fileHash ?? item.syncedAt.microsecondsSinceEpoch}',
        accountId: item.accountId,
        accountGeneration: accountGeneration,
      );
      if (bytes != null) return [bytes];
      if (item.mediaType == MediaTypeEnum.video) {
        final frames = await extractFrames();
        if (frames.isNotEmpty) return frames;
      }
      if (extractionError != null) {
        Error.throwWithStackTrace(extractionError!, extractionStackTrace!);
      }
      return const [];
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        AppLogger.error(
          'Face pipeline: 401 for account ${item.accountId} — marking expired',
        );
        _expiredAccounts.add(item.accountId);
        throw TokenExpiredException(
          'Access token expired for account ${item.accountId}',
        );
      } else if (item.mediaType == MediaTypeEnum.video) {
        // If provider thumbnail endpoint fails for videos, try extracting
        // from the original video stream before giving up.
        final frames = await extractFrames();
        if (frames.isNotEmpty) return frames;
        if (extractionError != null) {
          Error.throwWithStackTrace(extractionError!, extractionStackTrace!);
        }
        AppLogger.error(
          'Failed to get video thumbnail/frame for ${item.id}',
          error: e,
        );
      } else {
        AppLogger.error(
          'Failed to download thumbnail for ${item.id}',
          error: e,
        );
      }
      rethrow;
    }
  }

  Future<void> _markFacesProcessedIfCurrent(
    String mediaItemId,
    FaceProcessingContext expectedSource,
  ) async {
    await AccountOperationGate.runIfCurrent(
      expectedSource.accountId,
      expectedSource.accountGeneration,
      () => mediaItemsDao.transaction(() async {
        final current = await mediaItemsDao.getMediaItemById(mediaItemId);
        if (current == null ||
            current.isDeleted ||
            current.accountId != expectedSource.accountId ||
            current.fileHash != expectedSource.fileHash ||
            current.syncedAt != expectedSource.syncedAt) {
          return;
        }
        await mediaItemsDao.markFacesProcessed(mediaItemId);
      }),
    );
  }

  Future<List<Uint8List>> _extractVideoFrames(
    MediaItem item,
    Map<String, String> headers, {
    required int accountGeneration,
  }) async {
    if (!_videoThumbnailPluginAvailable ||
        !AccountOperationGate.isCurrent(item.accountId, accountGeneration)) {
      return const [];
    }

    try {
      final videoUrl = await _resolveVideoStreamUrl(
        item,
        headers,
        accountGeneration: accountGeneration,
      );
      if (videoUrl == null || videoUrl.isEmpty) return const [];

      final timestamps = _videoSampleTimestampsMs(item.durationSeconds);
      final frames = <Uint8List>[];
      // There are only a few samples.  Use their full bytes rather than a
      // sparse hash, which can collide for visually distinct video frames.
      final seenFrames = <String>{};

      for (final ts in timestamps) {
        final frame = _videoFrameExtractor == null
            ? await VideoThumbnail.thumbnailData(
                video: videoUrl,
                imageFormat: ImageFormat.JPEG,
                maxWidth: 720,
                quality: 75,
                timeMs: ts,
                headers: headers,
              )
            : await _videoFrameExtractor(
                videoUrl: videoUrl,
                timeMs: ts,
                headers: headers,
              );
        if (!AccountOperationGate.isCurrent(
          item.accountId,
          accountGeneration,
        )) {
          return const [];
        }
        if (frame == null || frame.isEmpty) continue;
        if (seenFrames.add(base64Encode(frame))) {
          frames.add(frame);
        }
      }
      return frames;
    } on MissingPluginException catch (e) {
      _videoThumbnailPluginAvailable = false;
      AppLogger.warning(
        'video_thumbnail plugin unavailable in current runtime; '
        'falling back to provider thumbnails only. Details: $e',
      );
      return const [];
    } catch (e) {
      AppLogger.error('Failed to extract video frame for ${item.id}', error: e);
      rethrow;
    }
  }

  List<int> _videoSampleTimestampsMs(int? durationSeconds) {
    if (durationSeconds == null || durationSeconds <= 0) {
      return const [500, 1500, 3000];
    }
    final totalMs = durationSeconds * 1000;
    final t1 = (totalMs * 0.10).round();
    final t2 = (totalMs * 0.35).round();
    final t3 = (totalMs * 0.60).round();
    final t4 = (totalMs * 0.85).round();
    final points = <int>{
      t1,
      t2,
      t3,
      t4,
    }.where((t) => t > 0 && t < totalMs).toList()..sort();
    if (points.isEmpty) return const [500, 1500, 3000];
    return points;
  }

  Future<String?> _resolveVideoStreamUrl(
    MediaItem item,
    Map<String, String> headers, {
    required int accountGeneration,
  }) async {
    if (!AccountOperationGate.isCurrent(item.accountId, accountGeneration)) {
      return null;
    }
    // Provider APIs return a current stream URL. Persisted OneDrive download
    // URLs are short-lived and must not take precedence over a fresh lookup.
    if (item.accountId.startsWith('google|')) {
      return '${ProviderConstants.googleDriveBaseUrl}/files/${item.remoteId}?alt=media';
    }

    if (item.accountId.startsWith('onedrive|')) {
      final response = await _dio.get(
        '${ProviderConstants.graphBaseUrl}/me/drive/items/${item.remoteId}',
        queryParameters: const {'select': '@microsoft.graph.downloadUrl'},
        options: Options(headers: headers),
      );
      if (!AccountOperationGate.isCurrent(item.accountId, accountGeneration)) {
        return null;
      }
      return response.data['@microsoft.graph.downloadUrl'] as String?;
    }

    if (item.accountId.startsWith('dropbox|')) {
      final path = item.remotePath;
      if (path == null || path.isEmpty) return null;
      final response = await _dio.post(
        '${ProviderConstants.dropboxApiBaseUrl}/files/get_temporary_link',
        options: Options(
          headers: {...headers, 'Content-Type': 'application/json'},
        ),
        data: jsonEncode({'path': path}),
      );
      if (!AccountOperationGate.isCurrent(item.accountId, accountGeneration)) {
        return null;
      }
      return response.data['link'] as String?;
    }

    return item.fullSizeUrl?.isNotEmpty == true ? item.fullSizeUrl : null;
  }
}
