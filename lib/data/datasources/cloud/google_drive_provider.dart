import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/constants/provider_constants.dart';
import '../../../core/enums/media_type.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/utils/logger.dart';
import '../../models/account_model.dart';
import '../../models/media_item_model.dart';
import '../../models/sync_result_model.dart';
import 'cloud_provider.dart';

class GoogleDriveProvider extends CloudProvider {
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  late final Dio _dio;
  final Dio _tokenDio = Dio();

  GoogleSignInAccount? _currentUser;
  bool _initialized = false;
  bool _isRefreshing = false;

  GoogleDriveProvider() {
    _dio = Dio(BaseOptions(
      baseUrl: ProviderConstants.googleDriveBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (error, handler) async {
        if (error.response?.statusCode == 401 &&
            !_isRefreshing &&
            refreshToken != null) {
          _isRefreshing = true;
          try {
            await refreshTokenIfNeeded(force: true);
            final headers = await getAuthHeaders();
            final opts = error.requestOptions;
            opts.headers.addAll(headers);
            final response = await _tokenDio.fetch(opts);
            _isRefreshing = false;
            return handler.resolve(response);
          } catch (e) {
            _isRefreshing = false;
            return handler.next(error);
          }
        }
        return handler.next(error);
      },
    ));
  }

  @override
  String get providerId => 'google';

  @override
  ProviderType get providerType => ProviderType.google;

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await _googleSignIn.initialize(
        serverClientId: ProviderConstants.googleWebClientId,
      );
      _initialized = true;
    }
  }

  @override
  Future<AccountModel> login() async {
    try {
      await _ensureInitialized();
      final account = await _googleSignIn.authenticate(
        scopeHint: [ProviderConstants.googleDriveScope],
      );
      _currentUser = account;

      final authz = await account.authorizationClient.authorizeScopes(
        [ProviderConstants.googleDriveScope],
      );
      final token = authz.accessToken;

      // Try to get a server auth code so we can exchange it for a refresh token.
      String? oauthRefreshToken;
      String finalAccessToken = token;
      DateTime expiry = DateTime.now().add(const Duration(hours: 1));

      try {
        final serverAuth = await account.authorizationClient.authorizeServer(
          [ProviderConstants.googleDriveScope],
        );
        if (serverAuth != null) {
          final exchanged = await _exchangeServerAuthCode(serverAuth.serverAuthCode);
          if (exchanged != null) {
            finalAccessToken = exchanged['access_token'] as String? ?? token;
            oauthRefreshToken = exchanged['refresh_token'] as String?;
            final expiresIn = exchanged['expires_in'] as int?;
            if (expiresIn != null) {
              expiry = DateTime.now().add(Duration(seconds: expiresIn));
            }
            AppLogger.info('Google login: obtained refresh token via server auth code');
          }
        }
      } catch (e) {
        AppLogger.error('Google login: server auth code exchange failed, using SDK token only', error: e);
      }

      if (oauthRefreshToken == null) {
        AppLogger.warning('Google login completed WITHOUT a refresh token. '
            'Token refresh will not be possible after expiry (~1 hour). '
            'User may need to revoke access at https://myaccount.google.com/permissions and re-link.');
      } else {
        AppLogger.info('Google login completed with refresh token.');
      }

      setTokens(
        accessToken: finalAccessToken,
        refreshToken: oauthRefreshToken,
        expiry: expiry,
      );

      return AccountModel(
        id: 'google|${account.email}',
        providerType: ProviderType.google,
        email: account.email,
        displayName: account.displayName,
        avatarUrl: account.photoUrl,
        accessToken: finalAccessToken,
        refreshToken: oauthRefreshToken,
        tokenExpiry: expiry,
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(message: 'Google sign-in failed', originalError: e);
    }
  }

  /// Exchanges a server auth code at Google's token endpoint for
  /// access + refresh tokens.  Returns the JSON map on success, null on failure.
  Future<Map<String, dynamic>?> _exchangeServerAuthCode(String code) async {
    try {
      final response = await _tokenDio.post(
        ProviderConstants.googleTokenEndpoint,
        options: Options(contentType: Headers.formUrlEncodedContentType),
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': ProviderConstants.googleWebClientId,
          'client_secret': ProviderConstants.googleClientSecret,
          'redirect_uri': '',
        },
      );
      final data = response.data as Map<String, dynamic>;
      AppLogger.info('Google token exchange response keys: ${data.keys.toList()}');
      if (data['refresh_token'] == null) {
        AppLogger.warning('Google token exchange: no refresh_token in response. '
            'User may need to revoke app access at https://myaccount.google.com/permissions '
            'and re-link to obtain a refresh token.');
      }
      return data;
    } on DioException catch (e) {
      AppLogger.error('Google token exchange failed (${e.response?.statusCode}): ${e.response?.data}', error: e);
      return null;
    }
  }

  @override
  Future<void> logout() async {
    await _ensureInitialized();
    await _googleSignIn.signOut();
    _currentUser = null;
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

    if (refreshToken != null) {
      try {
        final response = await _tokenDio.post(
          ProviderConstants.googleTokenEndpoint,
          options: Options(contentType: Headers.formUrlEncodedContentType),
          data: {
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'client_id': ProviderConstants.googleWebClientId,
            'client_secret': ProviderConstants.googleClientSecret,
          },
        );

        final data = response.data as Map<String, dynamic>;
        setTokens(
          accessToken: data['access_token'] as String,
          refreshToken: refreshToken,
          expiry: DateTime.now().add(Duration(seconds: data['expires_in'] as int)),
        );
        AppLogger.info('Google: silently refreshed token via refresh_token');
        return;
      } on DioException catch (e) {
        AppLogger.error('Google: refresh_token flow failed', error: e);
      }
    }

    // No refresh token or HTTP refresh failed. Use existing access token
    // as-is if available — the 401 interceptor will catch failures.
    // Never fall back to the Sign-In SDK here; it can show an account
    // picker or consent screen, which must only happen during setup.
    if (accessToken != null) {
      AppLogger.info('Google: no refresh token, using existing access token');
      return;
    }

    throw const AuthException(
      message: 'Session expired. Please re-link your Google account.',
    );
  }

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async {
    final headers = await getAuthHeaders();
    final changedItems = <MediaItemModel>[];
    final deletedIds = <String>[];

    AppLogger.info('Starting Google Drive scan (syncToken: ${syncToken != null ? "exists" : "null"})');

    try {
      if (syncToken == null) {
        String? pageToken;
        do {
          final response = await _dio.get(
            '/files',
            options: Options(headers: headers),
            queryParameters: {
              'q': "(mimeType contains 'image/' or mimeType contains 'video/') and trashed = false",
              'fields':
                  'nextPageToken,files(id,name,mimeType,thumbnailLink,webContentLink,imageMediaMetadata,videoMediaMetadata,md5Checksum,createdTime,modifiedTime,size)',
              'pageSize': 100,
              'orderBy': 'createdTime desc',
              if (pageToken != null) 'pageToken': pageToken,
            },
          );

          final data = response.data as Map<String, dynamic>;
          final files = (data['files'] as List?) ?? [];
          AppLogger.info('Google Drive scan page: found ${files.length} files');

          for (final file in files) {
            changedItems.add(_mapFileToMediaItem(file));
          }

          pageToken = data['nextPageToken'] as String?;
        } while (pageToken != null);

        final startPageResponse = await _dio.get(
          '/changes/startPageToken',
          options: Options(headers: headers),
        );
        final newToken = startPageResponse.data['startPageToken'] as String?;

        return SyncResultModel(
          changedItems: changedItems,
          deletedRemoteIds: deletedIds,
          newSyncToken: newToken,
        );
      } else {
        String? pageToken = syncToken;
        String? newStartPageToken;

        do {
          final response = await _dio.get(
            '/changes',
            options: Options(headers: headers),
            queryParameters: {
              'pageToken': pageToken,
              'fields':
                  'nextPageToken,newStartPageToken,changes(removed,fileId,file(id,name,mimeType,thumbnailLink,webContentLink,imageMediaMetadata,videoMediaMetadata,md5Checksum,createdTime,modifiedTime,size,trashed))',
              'pageSize': 100,
              'includeRemoved': true,
            },
          );

          final data = response.data as Map<String, dynamic>;
          final changes = (data['changes'] as List?) ?? [];

          for (final change in changes) {
            final removed = change['removed'] == true;
            final fileId = change['fileId'] as String?;
            final file = change['file'] as Map<String, dynamic>?;

            if (removed || file?['trashed'] == true) {
              if (fileId != null) deletedIds.add(fileId);
            } else if (file != null) {
              final mimeType = file['mimeType'] as String? ?? '';
              if (mimeType.startsWith('image/') ||
                  mimeType.startsWith('video/')) {
                changedItems.add(_mapFileToMediaItem(file));
              }
            }
          }

          pageToken = data['nextPageToken'] as String?;
          newStartPageToken = data['newStartPageToken'] as String?;
        } while (pageToken != null);

        return SyncResultModel(
          changedItems: changedItems,
          deletedRemoteIds: deletedIds,
          newSyncToken: newStartPageToken,
        );
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      String detail = e.message ?? 'Unknown error';
      if (e.response?.data is Map) {
        final errorMsg = (e.response!.data as Map)['error']?['message'];
        if (errorMsg != null) detail = errorMsg.toString();
      }
      throw ApiException(
        message: status == 401
            ? 'Google token expired. Please re-link your Google account in Settings.'
            : 'Google Drive sync failed ($status): $detail',
        statusCode: status,
        originalError: e,
      );
    }
  }

  @override
  Future<String> getVideoStreamUrl(String fileId) async {
    return '${ProviderConstants.googleDriveBaseUrl}/files/$fileId?alt=media';
  }

  @override
  Future<String> getThumbnailUrl(String fileId) async {
    final headers = await getAuthHeaders();
    final response = await _dio.get(
      '/files/$fileId',
      options: Options(headers: headers),
      queryParameters: {'fields': 'thumbnailLink'},
    );
    return response.data['thumbnailLink'] as String? ?? '';
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.toInt();
    return null;
  }

  MediaItemModel _mapFileToMediaItem(Map<String, dynamic> file) {
    final mimeType = file['mimeType'] as String? ?? 'image/jpeg';
    final imageMetadata = file['imageMediaMetadata'] as Map<String, dynamic>?;
    final videoMetadata = file['videoMediaMetadata'] as Map<String, dynamic>?;

    DateTime timestamp;
    try {
      timestamp = DateTime.parse(file['createdTime'] as String);
    } catch (_) {
      timestamp = DateTime.now();
    }

    final durationMillis = _parseInt(videoMetadata?['durationMillis']);

    return MediaItemModel(
      remoteId: file['id'] as String,
      fileName: file['name'] as String? ?? 'Untitled',
      mimeType: mimeType,
      mediaType: MediaItemModel.mediaTypeFromMime(mimeType),
      thumbnailUrl: 'gdrive://thumb/${file['id'] as String}',
      fullSizeUrl: file['webContentLink'] as String?,
      width: _parseInt(imageMetadata?['width']) ?? _parseInt(videoMetadata?['width']),
      height: _parseInt(imageMetadata?['height']) ?? _parseInt(videoMetadata?['height']),
      fileSize: _parseInt(file['size']),
      durationSeconds: durationMillis != null ? durationMillis ~/ 1000 : null,
      fileHash: file['md5Checksum'] as String?,
      timestamp: timestamp,
    );
  }
}
