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

class OneDriveProvider extends CloudProvider {
  final FlutterAppAuth _appAuth = const FlutterAppAuth();
  final Dio _dio = Dio(BaseOptions(
    baseUrl: ProviderConstants.graphBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  @override
  String get providerId => 'onedrive';

  @override
  ProviderType get providerType => ProviderType.onedrive;

  @override
  Future<AccountModel> login() async {
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          ProviderConstants.microsoftClientId,
          ProviderConstants.microsoftRedirectUri,
          discoveryUrl: ProviderConstants.microsoftDiscoveryUrl,
          scopes: ProviderConstants.microsoftScopes,
          promptValues: ['login'],
        ),
      );

      if (result == null || result.accessToken == null) {
        throw const AuthException(message: 'OneDrive sign-in failed');
      }

      setTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        expiry: result.accessTokenExpirationDateTime,
      );

      // Get user profile
      final headers = await getAuthHeaders();
      final profileResponse = await _dio.get(
        '/me',
        options: Options(headers: headers),
      );
      final profile = profileResponse.data as Map<String, dynamic>;
      final email = profile['mail'] as String? ??
          profile['userPrincipalName'] as String? ??
          'unknown';

      return AccountModel(
        id: 'onedrive|$email',
        providerType: ProviderType.onedrive,
        email: email,
        displayName: profile['displayName'] as String?,
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        tokenExpiry: result.accessTokenExpirationDateTime,
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(
          message: 'OneDrive sign-in failed', originalError: e);
    }
  }

  @override
  Future<void> logout() async {
    clearTokens();
  }

  @override
  Future<Map<String, String>> getAuthHeaders() async {
    await refreshTokenIfNeeded();
    return {'Authorization': 'Bearer $accessToken'};
  }

  @override
  Future<void> refreshTokenIfNeeded({bool force = false}) async {
    if (!force && !isTokenExpired && accessToken != null) return;
    if (refreshToken == null) {
      throw const AuthException(
          message: 'No refresh token available for OneDrive');
    }

    try {
      final result = await _appAuth.token(
        TokenRequest(
          ProviderConstants.microsoftClientId,
          ProviderConstants.microsoftRedirectUri,
          discoveryUrl: ProviderConstants.microsoftDiscoveryUrl,
          refreshToken: refreshToken,
          scopes: ProviderConstants.microsoftScopes,
        ),
      );

      if (result == null || result.accessToken == null) {
        throw const AuthException(message: 'OneDrive token refresh failed');
      }

      setTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken ?? refreshToken,
        expiry: result.accessTokenExpirationDateTime,
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(
          message: 'OneDrive token refresh failed', originalError: e);
    }
  }

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async {
    final headers = await getAuthHeaders();
    final changedItems = <MediaItemModel>[];
    final deletedIds = <String>[];

    try {
      String? nextLink;
      String? deltaLink;

      if (syncToken == null) {
        nextLink = '/me/drive/root/delta';
      } else {
        nextLink = '/me/drive/root/delta(token=\'$syncToken\')';
      }

      do {
        final response = await _dio.get(
          nextLink!,
          options: Options(headers: headers),
        );

        final data = response.data as Map<String, dynamic>;
        final items = (data['value'] as List?) ?? [];

        for (final item in items) {
          // Check if deleted
          if (item['deleted'] != null) {
            final id = item['id'] as String?;
            if (id != null) deletedIds.add(id);
            continue;
          }

          // Check if it's a file (not folder)
          final file = item['file'] as Map<String, dynamic>?;
          if (file == null) continue;

          final mimeType = file['mimeType'] as String? ?? '';
          if (!mimeType.startsWith('image/') &&
              !mimeType.startsWith('video/')) {
            continue;
          }

          changedItems.add(_mapItemToMediaItem(item));
        }

        nextLink = data['@odata.nextLink'] as String?;
        deltaLink = data['@odata.deltaLink'] as String?;
      } while (nextLink != null);

      // Extract token from deltaLink
      String? newToken;
      if (deltaLink != null) {
        final uri = Uri.parse(deltaLink);
        newToken = uri.queryParameters['token'] ?? deltaLink;
      }

      return SyncResultModel(
        changedItems: changedItems,
        deletedRemoteIds: deletedIds,
        newSyncToken: newToken,
      );
    } on DioException catch (e) {
      throw ApiException(
        message: 'OneDrive sync failed',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  @override
  Future<String> getVideoStreamUrl(String fileId) async {
    final headers = await getAuthHeaders();
    final response = await _dio.get(
      '/me/drive/items/$fileId',
      options: Options(headers: headers),
      queryParameters: {'select': '@microsoft.graph.downloadUrl'},
    );
    return response.data['@microsoft.graph.downloadUrl'] as String? ?? '';
  }

  @override
  Future<String> getThumbnailUrl(String fileId) async {
    final headers = await getAuthHeaders();
    try {
      final response = await _dio.get(
        '/me/drive/items/$fileId/thumbnails/0/large',
        options: Options(headers: headers),
      );
      return response.data['url'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  MediaItemModel _mapItemToMediaItem(Map<String, dynamic> item) {
    final file = item['file'] as Map<String, dynamic>? ?? {};
    final mimeType = file['mimeType'] as String? ?? 'image/jpeg';
    final image = item['image'] as Map<String, dynamic>?;
    final video = item['video'] as Map<String, dynamic>?;
    final photo = item['photo'] as Map<String, dynamic>?;

    DateTime timestamp;
    try {
      final takenStr = photo?['takenDateTime'] as String?;
      final createdStr = (item['createdDateTime'] as String?) ?? '';
      timestamp = DateTime.parse(takenStr ?? createdStr);
    } catch (_) {
      timestamp = DateTime.now();
    }

    final remoteId = item['id'] as String;
    return MediaItemModel(
      remoteId: remoteId,
      remotePath: item['parentReference']?['path'] as String?,
      fileName: item['name'] as String? ?? 'Untitled',
      mimeType: mimeType,
      mediaType: MediaItemModel.mediaTypeFromMime(mimeType),
      thumbnailUrl: '${ProviderConstants.graphBaseUrl}/me/drive/items/$remoteId/thumbnails/0/large/content',
      fullSizeUrl: item['@microsoft.graph.downloadUrl'] as String?,
      width: image?['width'] as int? ?? video?['width'] as int?,
      height: image?['height'] as int? ?? video?['height'] as int?,
      fileSize: item['size'] as int?,
      durationSeconds: video != null
          ? ((video['duration'] as int?) ?? 0) ~/ 1000
          : null,
      fileHash: item['file']?['hashes']?['sha1Hash'] as String?,
      timestamp: timestamp,
    );
  }
}
