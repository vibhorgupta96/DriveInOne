import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import '../../../core/constants/provider_constants.dart';
import '../../../core/enums/media_type.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/utils/logger.dart';
import '../../models/account_model.dart';
import '../../models/media_item_model.dart';
import '../../models/sync_result_model.dart';
import 'cloud_provider.dart';

class DropboxProvider extends CloudProvider {
  final FlutterAppAuth _appAuth = const FlutterAppAuth();
  final Dio _apiDio = Dio(BaseOptions(
    baseUrl: ProviderConstants.dropboxApiBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));
  final Dio _contentDio = Dio(BaseOptions(
    baseUrl: ProviderConstants.dropboxContentBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  @override
  String get providerId => 'dropbox';

  @override
  ProviderType get providerType => ProviderType.dropbox;

  @override
  Future<AccountModel> login() async {
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          ProviderConstants.dropboxAppKey,
          ProviderConstants.dropboxRedirectUri,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: ProviderConstants.dropboxAuthEndpoint,
            tokenEndpoint: ProviderConstants.dropboxTokenEndpoint,
          ),
          scopes: ProviderConstants.dropboxScopes,
          additionalParameters: {'token_access_type': 'offline'},
        ),
      );

      if (result == null || result.accessToken == null) {
        throw const AuthException(message: 'Dropbox sign-in failed');
      }

      setTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        expiry: result.accessTokenExpirationDateTime,
      );

      // Get user profile
      final headers = await getAuthHeaders();
      final profileResponse = await _apiDio.post(
        '/users/get_current_account',
        options: Options(headers: {
          ...headers,
          'Content-Type': 'application/json',
        }),
        data: 'null',
      );
      final profile = profileResponse.data as Map<String, dynamic>;
      final email = profile['email'] as String? ?? 'unknown';
      final name = profile['name'] as Map<String, dynamic>?;

      return AccountModel(
        id: 'dropbox|$email',
        providerType: ProviderType.dropbox,
        email: email,
        displayName: name?['display_name'] as String?,
        avatarUrl: profile['profile_photo_url'] as String?,
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        tokenExpiry: result.accessTokenExpirationDateTime,
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(message: 'Dropbox sign-in failed', originalError: e);
    }
  }

  @override
  Future<void> logout() async {
    try {
      final headers = await getAuthHeaders();
      await _apiDio.post(
        '/auth/token/revoke',
        options: Options(headers: headers),
        data: 'null',
      );
    } catch (_) {
      // Best effort revocation
    }
    clearTokens();
  }

  @override
  Future<Map<String, String>> getAuthHeaders() async {
    await refreshTokenIfNeeded();
    return {'Authorization': 'Bearer $accessToken'};
  }

  @override
  Future<void> refreshTokenIfNeeded() async {
    if (!isTokenExpired && accessToken != null) return;
    if (_refreshToken == null) {
      throw const AuthException(
          message: 'No refresh token available for Dropbox');
    }

    try {
      final result = await _appAuth.token(
        TokenRequest(
          ProviderConstants.dropboxAppKey,
          ProviderConstants.dropboxRedirectUri,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: ProviderConstants.dropboxAuthEndpoint,
            tokenEndpoint: ProviderConstants.dropboxTokenEndpoint,
          ),
          refreshToken: _refreshToken,
          scopes: ProviderConstants.dropboxScopes,
        ),
      );

      if (result == null || result.accessToken == null) {
        throw const AuthException(message: 'Dropbox token refresh failed');
      }

      setTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken ?? _refreshToken,
        expiry: result.accessTokenExpirationDateTime,
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(
          message: 'Dropbox token refresh failed', originalError: e);
    }
  }

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async {
    final headers = await getAuthHeaders();
    final changedItems = <MediaItemModel>[];
    final deletedIds = <String>[];

    try {
      Map<String, dynamic> data;
      bool hasMore = true;
      String? cursor = syncToken;

      while (hasMore) {
        Response response;

        if (cursor == null) {
          response = await _apiDio.post(
            '/files/list_folder',
            options: Options(headers: {
              ...headers,
              'Content-Type': 'application/json',
            }),
            data: jsonEncode({
              'path': '',
              'recursive': true,
              'include_media_info': true,
              'include_deleted': true,
              'limit': 100,
            }),
          );
        } else {
          response = await _apiDio.post(
            '/files/list_folder/continue',
            options: Options(headers: {
              ...headers,
              'Content-Type': 'application/json',
            }),
            data: jsonEncode({'cursor': cursor}),
          );
        }

        data = response.data as Map<String, dynamic>;
        final entries = (data['entries'] as List?) ?? [];

        for (final entry in entries) {
          final tag = entry['.tag'] as String?;

          if (tag == 'deleted') {
            final pathLower = entry['path_lower'] as String?;
            if (pathLower != null) deletedIds.add(pathLower);
            continue;
          }

          if (tag != 'file') continue;

          final mediaInfo = entry['media_info'] as Map<String, dynamic>?;
          final metadata = mediaInfo?['metadata'] as Map<String, dynamic>?;
          final mediaTag = metadata?['.tag'] as String?;

          // Check if it's a photo or video
          final name = (entry['name'] as String? ?? '').toLowerCase();
          final isMedia = mediaTag == 'photo' ||
              mediaTag == 'video' ||
              _isMediaFile(name);

          if (!isMedia) continue;

          changedItems.add(_mapEntryToMediaItem(entry));
        }

        cursor = data['cursor'] as String?;
        hasMore = data['has_more'] as bool? ?? false;
      }

      return SyncResultModel(
        changedItems: changedItems,
        deletedRemoteIds: deletedIds,
        newSyncToken: cursor,
      );
    } on DioException catch (e) {
      throw ApiException(
        message: 'Dropbox sync failed',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  @override
  Future<String> getVideoStreamUrl(String fileId) async {
    final headers = await getAuthHeaders();
    final response = await _apiDio.post(
      '/files/get_temporary_link',
      options: Options(headers: {
        ...headers,
        'Content-Type': 'application/json',
      }),
      data: jsonEncode({'path': fileId}),
    );
    return response.data['link'] as String? ?? '';
  }

  @override
  Future<String> getThumbnailUrl(String fileId) async {
    // Dropbox thumbnails are fetched via content endpoint with Dropbox-API-Arg header
    // Return a marker URL that AuthenticatedImage will handle
    return 'dropbox://thumbnail$fileId';
  }

  bool _isMediaFile(String name) {
    const imageExtensions = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.heic',
      '.heif',
      '.tiff'
    ];
    const videoExtensions = [
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v'
    ];
    return imageExtensions.any(name.endsWith) ||
        videoExtensions.any(name.endsWith);
  }

  MediaItemModel _mapEntryToMediaItem(Map<String, dynamic> entry) {
    final name = entry['name'] as String? ?? 'Untitled';
    final pathLower = entry['path_lower'] as String? ?? '';
    final mediaInfo = entry['media_info'] as Map<String, dynamic>?;
    final metadata = mediaInfo?['metadata'] as Map<String, dynamic>?;
    final mediaTag = metadata?['.tag'] as String? ?? '';

    String mimeType;
    MediaType mediaType;
    if (mediaTag == 'video' || _isVideoFile(name.toLowerCase())) {
      mimeType = 'video/${_getExtension(name)}';
      mediaType = MediaType.video;
    } else {
      mimeType = 'image/${_getExtension(name)}';
      mediaType = MediaType.photo;
    }

    final dimensions = metadata?['dimensions'] as Map<String, dynamic>?;
    final timeTaken = metadata?['time_taken'] as String?;

    DateTime timestamp;
    try {
      timestamp = DateTime.parse(
        timeTaken ??
            entry['client_modified'] as String? ??
            DateTime.now().toIso8601String(),
      );
    } catch (_) {
      timestamp = DateTime.now();
    }

    int? duration;
    if (metadata?['duration'] != null) {
      duration = (metadata!['duration'] as num).toInt() ~/ 1000;
    }

    return MediaItemModel(
      remoteId: entry['id'] as String? ?? pathLower,
      remotePath: pathLower,
      fileName: name,
      mimeType: mimeType,
      mediaType: mediaType,
      thumbnailUrl: null, // Fetched via special Dropbox thumbnail API
      fullSizeUrl: null, // Requires temporary link
      width: dimensions?['width'] as int?,
      height: dimensions?['height'] as int?,
      fileSize: entry['size'] as int?,
      durationSeconds: duration,
      fileHash: entry['content_hash'] as String?,
      timestamp: timestamp,
    );
  }

  bool _isVideoFile(String name) {
    const videoExtensions = [
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v'
    ];
    return videoExtensions.any(name.endsWith);
  }

  String _getExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1) return 'unknown';
    return name.substring(dotIndex + 1);
  }
}
