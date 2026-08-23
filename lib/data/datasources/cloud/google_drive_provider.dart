import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/constants/provider_constants.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/utils/logger.dart';
import '../../models/account_model.dart';
import '../../models/media_item_model.dart';
import '../../models/sync_result_model.dart';
import 'cloud_provider.dart';

class GoogleDriveProvider extends CloudProvider {
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static Future<void>? _initialization;

  final String? accountId;
  late final Dio _dio;
  final Dio _retryDio = Dio();

  GoogleSignInAccount? _currentUser;
  Future<void>? _refreshFuture;

  GoogleDriveProvider({this.accountId}) {
    _dio = Dio(BaseOptions(
      baseUrl: ProviderConstants.googleDriveBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (error, handler) async {
        if (error.response?.statusCode == 401 &&
            error.requestOptions.extra['googleAuthRetried'] != true) {
          try {
            if (_refreshFuture != null) {
              await _refreshFuture;
            } else {
              final refresh = refreshTokenIfNeeded(force: true);
              _refreshFuture = refresh;
              try {
                await refresh;
              } finally {
                _refreshFuture = null;
              }
            }
            final headers = await getAuthHeaders();
            final opts = error.requestOptions;
            opts.extra['googleAuthRetried'] = true;
            opts.headers.addAll(headers);
            final response = await _retryDio.fetch(opts);
            return handler.resolve(response);
          } catch (e) {
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
    if (_initialization != null) return _initialization!;

    final webClientId = ProviderConstants.requireConfigured(
      ProviderConstants.googleWebClientId,
      'GOOGLE_WEB_CLIENT_ID',
    );
    String? clientId;
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      clientId = ProviderConstants.requireConfigured(
        ProviderConstants.googleIosClientId,
        'GOOGLE_IOS_CLIENT_ID',
      );
    }
    return _initialization = _googleSignIn.initialize(
      clientId: clientId,
      serverClientId: webClientId,
    );
  }

  @override
  Future<AccountModel> login() async {
    try {
      await _ensureInitialized();
      final account = await _googleSignIn.authenticate(
        scopeHint: [ProviderConstants.googleDriveScope],
      );
      _currentUser = account;

      // This method is reached only from the explicit Link Account action, so
      // an interactive scope grant is allowed here if the combined flow did
      // not already authorize Drive.
      final authz = await account.authorizationClient.authorizationForScopes(
            [ProviderConstants.googleDriveScope],
          ) ??
          await account.authorizationClient.authorizeScopes(
            [ProviderConstants.googleDriveScope],
          );
      final token = authz.accessToken;
      final expiry = _estimatedGoogleExpiry();

      setTokens(
        accessToken: token,
        expiry: expiry,
      );

      return AccountModel(
        id: 'google|${account.email}',
        providerType: ProviderType.google,
        email: account.email,
        displayName: account.displayName,
        avatarUrl: account.photoUrl,
        accessToken: token,
        tokenExpiry: expiry,
      );
    } on StateError catch (e) {
      throw AuthException(message: e.message);
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(message: 'Google sign-in failed', originalError: e);
    }
  }

  @override
  Future<void> logout() async {
    await _ensureInitialized();
    // Google Sign-In currently has process-wide sign-in state. Only sign out a
    // user authenticated by this provider instance; an account-scoped unlink
    // must not accidentally sign out a different linked account.
    if (_currentUser != null) await _googleSignIn.signOut();
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
    await _ensureInitialized();

    final oldToken = accessToken;
    if (force && oldToken != null) {
      try {
        await _googleSignIn.authorizationClient.clearAuthorizationToken(
          accessToken: oldToken,
        );
      } catch (error) {
        AppLogger.warning(
            'Could not clear the cached Google access token: $error');
      }
    }

    final account = _currentUser ?? await _restoreAccountSilently();
    final authorization = await account.authorizationClient
        .authorizationForScopes([ProviderConstants.googleDriveScope]);
    if (authorization == null) {
      throw const AuthException(
        message:
            'Google Drive authorization expired. Please re-link the account.',
      );
    }

    _currentUser = account;
    setTokens(
      accessToken: authorization.accessToken,
      expiry: _estimatedGoogleExpiry(),
    );
  }

  Future<GoogleSignInAccount> _restoreAccountSilently() async {
    final attempt = _googleSignIn.attemptLightweightAuthentication();
    if (attempt == null) {
      throw const AuthException(
        message:
            'Google session cannot be restored silently. Please re-link the account.',
      );
    }

    final account = await attempt;
    if (account == null) {
      throw const AuthException(
        message: 'Google session expired. Please re-link the account.',
      );
    }
    if (accountId != null && accountId != 'google|${account.email}') {
      throw AuthException(
        message:
            'Google is signed in as ${account.email}, not the requested account. '
            'Please re-link $accountId.',
      );
    }
    return account;
  }

  static DateTime _estimatedGoogleExpiry() =>
      DateTime.now().add(const Duration(minutes: 55));

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async {
    final headers = await getAuthHeaders();
    final changedItems = <MediaItemModel>[];
    final deletedIds = <String>[];

    AppLogger.info(
        'Starting Google Drive scan (syncToken: ${syncToken != null ? "exists" : "null"})');

    try {
      if (syncToken == null) {
        String? pageToken;
        do {
          final response = await _dio.get(
            '/files',
            options: Options(headers: headers),
            queryParameters: {
              'q':
                  "(mimeType contains 'image/' or mimeType contains 'video/') and trashed = false",
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
      width: _parseInt(imageMetadata?['width']) ??
          _parseInt(videoMetadata?['width']),
      height: _parseInt(imageMetadata?['height']) ??
          _parseInt(videoMetadata?['height']),
      fileSize: _parseInt(file['size']),
      durationSeconds: durationMillis != null ? durationMillis ~/ 1000 : null,
      fileHash: file['md5Checksum'] as String?,
      timestamp: timestamp,
    );
  }
}
