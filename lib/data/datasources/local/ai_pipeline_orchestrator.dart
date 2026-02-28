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

class TokenExpiredException implements Exception {
  final String message;
  const TokenExpiredException(this.message);
  @override
  String toString() => message;
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

  static const idle = PipelineProgress(processed: 0, total: 0, isRunning: false);
}

class AIPipelineOrchestrator {
  final FaceRepository faceRepository;
  final MediaItemsDao mediaItemsDao;
  final AccountsDao accountsDao;
  final SecureStorageSource secureStorage;
  final Dio _dio = Dio();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  final _progressController = StreamController<PipelineProgress>.broadcast();
  Stream<PipelineProgress> get progressStream => _progressController.stream;

  AIPipelineOrchestrator({
    required this.faceRepository,
    required this.mediaItemsDao,
    required this.accountsDao,
    required this.secureStorage,
  });

  final Map<String, Map<String, String>> _authHeadersCache = {};
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
        final accessToken = await secureStorage.getAccessToken(account.id);
        if (accessToken == null) {
          AppLogger.error('Face pipeline: no stored token for ${account.id}, skipping');
          continue;
        }

        _authHeadersCache[account.id] = {
          'Authorization': 'Bearer $accessToken',
        };
        AppLogger.info('Face pipeline: using stored token for ${account.id}');
      } catch (e) {
        AppLogger.error('Face pipeline: failed to load token for ${account.id}', error: e);
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
  Future<void> processNewMedia({int batchSize = AppConstants.faceBatchSize}) async {
    if (_isRunning) return;
    _isRunning = true;

    try {
      final totalMedia = await mediaItemsDao.getMediaCount();
      final allUnprocessed = await mediaItemsDao.getMediaItemsWithoutFaces(10000);
      final total = allUnprocessed.length;
      AppLogger.info('Face pipeline: $total unprocessed out of $totalMedia total media items');

      if (total > 0) {
        final withThumb = allUnprocessed.where((i) => i.thumbnailUrl != null && i.thumbnailUrl!.isNotEmpty).length;
        final constructable = allUnprocessed.where((i) =>
            (i.thumbnailUrl == null || i.thumbnailUrl!.isEmpty) && _constructThumbnailUrl(i) != null).length;
        AppLogger.info('Face pipeline: $withThumb have thumbnailUrl, $constructable can construct URL, '
            '${total - withThumb - constructable} have no thumbnail source');
        await _prepareAuthHeaders();

        int processed = 0;
        final skippedIds = <String>{};

        AppLogger.info('Face pipeline: starting, $total items to process');
        _progressController.add(PipelineProgress(processed: 0, total: total, isRunning: true));

        while (true) {
          final items = await mediaItemsDao.getMediaItemsWithoutFaces(batchSize);
          if (items.isEmpty) break;

          final toProcess = items.where((i) =>
              !skippedIds.contains(i.id) && !_expiredAccounts.contains(i.accountId)).toList();
          if (toProcess.isEmpty) break;

          for (final item in toProcess) {
            if (_expiredAccounts.contains(item.accountId)) {
              skippedIds.add(item.id);
              continue;
            }

            try {
              if (item.mediaType == MediaTypeEnum.video) {
                final headers = _authHeadersCache[item.accountId];
                final frames = headers == null
                    ? const <Uint8List>[]
                    : await _extractVideoFrames(item, headers);

                if (frames.isEmpty) {
                  // Fallback to provider thumbnail path when frame extraction fails.
                  final thumbnailBytes = await _downloadThumbnail(item);
                  if (thumbnailBytes != null) {
                    await faceRepository.processMediaItem(item.id, thumbnailBytes);
                  }
                } else {
                  for (final frame in frames) {
                    await faceRepository.processMediaItem(item.id, frame);
                  }
                }

                await mediaItemsDao.markFacesProcessed(item.id);
                processed++;
                _progressController.add(
                  PipelineProgress(processed: processed, total: total, isRunning: true),
                );
                continue;
              }

              final thumbnailBytes = await _downloadThumbnail(item);
              if (thumbnailBytes == null) {
                await mediaItemsDao.markFacesProcessed(item.id);
                processed++;
                _progressController.add(
                  PipelineProgress(processed: processed, total: total, isRunning: true),
                );
                continue;
              }

              await faceRepository.processMediaItem(item.id, thumbnailBytes);
            } catch (e) {
              AppLogger.error('Failed to process media item ${item.id}', error: e);
              skippedIds.add(item.id);
            }
            processed++;
            _progressController.add(PipelineProgress(processed: processed, total: total, isRunning: true));
          }

          await faceRepository.runClustering();
        }

        if (_expiredAccounts.isNotEmpty) {
          AppLogger.info('Face pipeline: tokens expired for accounts: '
              '${_expiredAccounts.join(', ')}. Sync those accounts to process remaining items.');
        }
        AppLogger.info('Face pipeline: complete, processed $processed items, '
            '${skippedIds.length} skipped due to errors');
      } else {
        AppLogger.info('Face pipeline: no unprocessed media items');
      }
    } catch (e) {
      AppLogger.error('Face pipeline failed', error: e);
      rethrow;
    } finally {
      try {
        await faceRepository.runClustering();
      } catch (e) {
        AppLogger.error('Face pipeline: final clustering failed', error: e);
      }
      _isRunning = false;
      _authHeadersCache.clear();
      _expiredAccounts.clear();
      _progressController.add(PipelineProgress.idle);
    }
  }

  /// Constructs a thumbnail URL for items that were synced before providers
  /// started persisting stable thumbnail URL patterns.
  String? _constructThumbnailUrl(MediaItem item) {
    if (item.accountId.startsWith('dropbox|') && item.remotePath != null && item.remotePath!.isNotEmpty) {
      return 'dropbox://thumbnail${item.remotePath}';
    }
    if (item.accountId.startsWith('onedrive|')) {
      return 'https://graph.microsoft.com/v1.0/me/drive/items/${item.remoteId}/thumbnails/0/large/content';
    }
    if (item.accountId.startsWith('google|')) {
      return 'gdrive://thumb/${item.remoteId}';
    }
    return null;
  }

  /// Returns null only when no thumbnail can be obtained (permanent condition).
  /// Throws on transient download errors so the caller can skip without
  /// marking the item as processed.
  Future<Uint8List?> _downloadThumbnail(MediaItem item) async {
    var thumbnailUrl = item.thumbnailUrl;
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
      // For videos, fall back to extracting a frame from stream URL when
      // providers don't expose thumbnails in metadata.
      if (item.mediaType == MediaTypeEnum.video) {
        final headers = _authHeadersCache[item.accountId];
        if (headers != null) {
          final frame = await _extractVideoFrame(item, headers);
          if (frame != null) return frame;
        }
      }
      thumbnailUrl = _constructThumbnailUrl(item);
      if (thumbnailUrl == null) return null;
    }

    // Convert stale googleusercontent.com URLs to the stable gdrive:// pattern
    // so we always fetch a fresh thumbnail link from the API.
    if (thumbnailUrl.contains('googleusercontent.com') && item.accountId.startsWith('google|')) {
      thumbnailUrl = 'gdrive://thumb/${item.remoteId}';
    }

    final headers = _authHeadersCache[item.accountId];
    if (headers == null) return null;

    try {
      if (thumbnailUrl.startsWith('dropbox://thumbnail')) {
        return _downloadDropboxThumbnail(thumbnailUrl, headers);
      }

      if (thumbnailUrl.startsWith('gdrive://thumb/')) {
        final bytes = await _downloadGDriveThumbnail(thumbnailUrl, headers);
        if (bytes != null) return bytes;
        if (item.mediaType == MediaTypeEnum.video) {
          return _extractVideoFrame(item, headers);
        }
        return null;
      }

      final response = await _dio.get(
        thumbnailUrl,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        AppLogger.error('Face pipeline: 401 for account ${item.accountId} — marking expired');
        _expiredAccounts.add(item.accountId);
      } else if (item.mediaType == MediaTypeEnum.video) {
        // If provider thumbnail endpoint fails for videos, try extracting
        // from the original video stream before giving up.
        final frame = await _extractVideoFrame(item, headers);
        if (frame != null) return frame;
        AppLogger.error('Failed to get video thumbnail/frame for ${item.id}', error: e);
      } else {
        AppLogger.error('Failed to download thumbnail for ${item.id}', error: e);
      }
      rethrow;
    }
  }

  Future<Uint8List> _downloadDropboxThumbnail(String url, Map<String, String> headers) async {
    final path = url.replaceFirst('dropbox://thumbnail', '');
    final apiArg = jsonEncode({
      'resource': {'.tag': 'path', 'path': path},
      'format': 'jpeg',
      'size': 'w640h480',
    });
    final response = await _dio.post(
      'https://content.dropboxapi.com/2/files/get_thumbnail_v2',
      options: Options(
        headers: {...headers, 'Dropbox-API-Arg': apiArg},
        responseType: ResponseType.bytes,
      ),
    );
    return Uint8List.fromList(response.data);
  }

  /// Fetches a fresh thumbnailLink from the Google Drive API, then downloads
  /// the actual thumbnail bytes. This avoids stale/expired thumbnail URLs.
  Future<Uint8List?> _downloadGDriveThumbnail(String url, Map<String, String> headers) async {
    final fileId = url.replaceFirst('gdrive://thumb/', '');

    final metaResponse = await _dio.get(
      'https://www.googleapis.com/drive/v3/files/$fileId',
      queryParameters: {'fields': 'thumbnailLink'},
      options: Options(headers: headers),
    );

    final freshLink = metaResponse.data['thumbnailLink'] as String?;
    if (freshLink == null || freshLink.isEmpty) return null;

    // Request larger thumbnail (default is ~220px)
    final upgradedLink = freshLink.replaceFirst(RegExp(r'=s\d+'), '=s800');

    final thumbResponse = await _dio.get(
      upgradedLink,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(thumbResponse.data);
  }

  Future<Uint8List?> _extractVideoFrame(MediaItem item, Map<String, String> headers) async {
    final frames = await _extractVideoFrames(item, headers);
    return frames.isNotEmpty ? frames.first : null;
  }

  Future<List<Uint8List>> _extractVideoFrames(MediaItem item, Map<String, String> headers) async {
    if (!_videoThumbnailPluginAvailable) return const [];

    try {
      final videoUrl = await _resolveVideoStreamUrl(item, headers);
      if (videoUrl == null || videoUrl.isEmpty) return const [];

      final timestamps = _videoSampleTimestampsMs(item.durationSeconds);
      final frames = <Uint8List>[];
      final seenHashes = <int>{};

      for (final ts in timestamps) {
        final frame = await VideoThumbnail.thumbnailData(
          video: videoUrl,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 720,
          quality: 75,
          timeMs: ts,
          headers: headers,
        );
        if (frame == null || frame.isEmpty) continue;
        final frameHash = _quickBytesHash(frame);
        if (seenHashes.add(frameHash)) {
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
      return const [];
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
    final points = <int>{t1, t2, t3, t4}
        .where((t) => t > 0 && t < totalMs)
        .toList()
      ..sort();
    if (points.isEmpty) return const [500, 1500, 3000];
    return points;
  }

  int _quickBytesHash(Uint8List bytes) {
    int hash = 17;
    for (int i = 0; i < bytes.length; i += 97) {
      hash = 37 * hash + bytes[i];
    }
    hash = 37 * hash + bytes.length;
    return hash;
  }

  Future<String?> _resolveVideoStreamUrl(MediaItem item, Map<String, String> headers) async {
    // Prefer a direct URL if already available.
    if (item.fullSizeUrl != null && item.fullSizeUrl!.isNotEmpty) {
      return item.fullSizeUrl;
    }

    if (item.accountId.startsWith('google|')) {
      return '${ProviderConstants.googleDriveBaseUrl}/files/${item.remoteId}?alt=media';
    }

    if (item.accountId.startsWith('onedrive|')) {
      final response = await _dio.get(
        '${ProviderConstants.graphBaseUrl}/me/drive/items/${item.remoteId}',
        queryParameters: const {'select': '@microsoft.graph.downloadUrl'},
        options: Options(headers: headers),
      );
      return response.data['@microsoft.graph.downloadUrl'] as String?;
    }

    if (item.accountId.startsWith('dropbox|')) {
      final path = item.remotePath;
      if (path == null || path.isEmpty) return null;
      final response = await _dio.post(
        '${ProviderConstants.dropboxApiBaseUrl}/files/get_temporary_link',
        options: Options(headers: {
          ...headers,
          'Content-Type': 'application/json',
        }),
        data: jsonEncode({'path': path}),
      );
      return response.data['link'] as String?;
    }

    return null;
  }
}
