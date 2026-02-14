import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/repositories/face_repository.dart';
import '../../database/daos/accounts_dao.dart';
import '../../database/daos/media_items_dao.dart';
import '../../database/tables/accounts_table.dart';
import '../../database/tables/media_items_table.dart';
import '../cloud/cloud_provider.dart';
import '../../datasources/local/secure_storage_source.dart';

class AIPipelineOrchestrator {
  final FaceRepository faceRepository;
  final MediaItemsDao mediaItemsDao;
  final AccountsDao accountsDao;
  final Map<ProviderType, CloudProvider> providers;
  final SecureStorageSource secureStorage;
  final Dio _dio = Dio();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  AIPipelineOrchestrator({
    required this.faceRepository,
    required this.mediaItemsDao,
    required this.accountsDao,
    required this.providers,
    required this.secureStorage,
  });

  ProviderType _enumToProviderType(ProviderTypeEnum e) {
    switch (e) {
      case ProviderTypeEnum.google:
        return ProviderType.google;
      case ProviderTypeEnum.onedrive:
        return ProviderType.onedrive;
      case ProviderTypeEnum.dropbox:
        return ProviderType.dropbox;
    }
  }

  /// Processes unscanned media items in batches.
  Future<void> processNewMedia({int batchSize = AppConstants.faceBatchSize}) async {
    if (_isRunning) return;
    _isRunning = true;

    try {
      while (true) {
        final items = await mediaItemsDao.getMediaItemsWithoutFaces(batchSize);
        if (items.isEmpty) break;

        for (final item in items) {
          try {
            final thumbnailBytes = await _downloadThumbnail(item);
            if (thumbnailBytes == null) {
              await mediaItemsDao.markFacesProcessed(item.id);
              continue;
            }

            await faceRepository.processMediaItem(item.id, thumbnailBytes);
          } catch (e) {
            AppLogger.error('Failed to process media item ${item.id}', error: e);
            await mediaItemsDao.markFacesProcessed(item.id);
          }
        }

        // Run clustering after each batch
        await faceRepository.runClustering();
      }
    } finally {
      _isRunning = false;
    }
  }

  Future<Uint8List?> _downloadThumbnail(MediaItem item) async {
    try {
      final thumbnailUrl = item.thumbnailUrl;
      if (thumbnailUrl == null || thumbnailUrl.isEmpty) return null;

      // Get account for auth headers
      final account = await accountsDao.getAccountById(item.accountId);
      if (account == null) return null;

      final providerType = _enumToProviderType(account.providerType);
      final provider = providers[providerType];
      if (provider == null) return null;

      // Restore tokens
      final accessToken = await secureStorage.getAccessToken(item.accountId);
      if (accessToken != null) {
        final refreshToken = await secureStorage.getRefreshToken(item.accountId);
        final expiry = await secureStorage.getTokenExpiry(item.accountId);
        provider.setTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
        );
      }

      final headers = await provider.getAuthHeaders();

      // Handle Dropbox special thumbnail URL
      if (thumbnailUrl.startsWith('dropbox://thumbnail')) {
        final path = thumbnailUrl.replaceFirst('dropbox://thumbnail', '');
        final response = await _dio.post(
          'https://content.dropboxapi.com/2/files/get_thumbnail_v2',
          options: Options(
            headers: {
              ...headers,
              'Dropbox-API-Arg': '{"resource":{".tag":"path","path":"$path"},"format":"jpeg","size":"w256h256"}',
            },
            responseType: ResponseType.bytes,
          ),
        );
        return Uint8List.fromList(response.data);
      }

      // Standard thumbnail download
      final response = await _dio.get(
        thumbnailUrl,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(response.data);
    } catch (e) {
      AppLogger.error('Failed to download thumbnail for ${item.id}', error: e);
      return null;
    }
  }
}
