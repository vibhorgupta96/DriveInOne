import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:uuid/uuid.dart';
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
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [ProviderConstants.googleDriveScope],
  );
  final Dio _dio = Dio(BaseOptions(
    baseUrl: ProviderConstants.googleDriveBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  GoogleSignInAccount? _currentUser;

  @override
  String get providerId => 'google';

  @override
  ProviderType get providerType => ProviderType.google;

  @override
  Future<AccountModel> login() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        throw const AuthException(message: 'Google sign-in was cancelled');
      }
      _currentUser = account;
      final auth = await account.authentication;

      setTokens(
        accessToken: auth.accessToken!,
        refreshToken: null, // Google Sign-In handles refresh internally
        expiry: DateTime.now().add(const Duration(hours: 1)),
      );

      return AccountModel(
        id: 'google|${account.email}',
        providerType: ProviderType.google,
        email: account.email,
        displayName: account.displayName,
        avatarUrl: account.photoUrl,
        accessToken: auth.accessToken!,
        refreshToken: null,
        tokenExpiry: DateTime.now().add(const Duration(hours: 1)),
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(message: 'Google sign-in failed', originalError: e);
    }
  }

  @override
  Future<void> logout() async {
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
  Future<void> refreshTokenIfNeeded() async {
    if (!isTokenExpired && accessToken != null) return;

    try {
      _currentUser = await _googleSignIn.signInSilently();
      if (_currentUser == null) {
        throw const AuthException(message: 'Failed to refresh Google token');
      }
      final auth = await _currentUser!.authentication;
      setTokens(
        accessToken: auth.accessToken!,
        expiry: DateTime.now().add(const Duration(hours: 1)),
      );
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException(message: 'Token refresh failed', originalError: e);
    }
  }

  @override
  Future<SyncResultModel> scanDelta(String? syncToken) async {
    final headers = await getAuthHeaders();
    final changedItems = <MediaItemModel>[];
    final deletedIds = <String>[];

    try {
      if (syncToken == null) {
        // Initial full scan
        String? pageToken;
        do {
          final response = await _dio.get(
            '/files',
            options: Options(headers: headers),
            queryParameters: {
              'q': "mimeType contains 'image/' or mimeType contains 'video/'",
              'fields':
                  'nextPageToken,files(id,name,mimeType,thumbnailLink,webContentLink,imageMediaMetadata,videoMediaMetadata,md5Checksum,createdTime,modifiedTime,size)',
              'pageSize': 100,
              'orderBy': 'createdTime desc',
              if (pageToken != null) 'pageToken': pageToken,
            },
          );

          final data = response.data as Map<String, dynamic>;
          final files = (data['files'] as List?) ?? [];

          for (final file in files) {
            changedItems.add(_mapFileToMediaItem(file));
          }

          pageToken = data['nextPageToken'] as String?;
        } while (pageToken != null);

        // Get the initial changes token
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
        // Delta sync using Changes API
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
      throw ApiException(
        message: 'Google Drive sync failed',
        statusCode: e.response?.statusCode,
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

    return MediaItemModel(
      remoteId: file['id'] as String,
      fileName: file['name'] as String? ?? 'Untitled',
      mimeType: mimeType,
      mediaType: MediaItemModel.mediaTypeFromMime(mimeType),
      thumbnailUrl: file['thumbnailLink'] as String?,
      fullSizeUrl: file['webContentLink'] as String?,
      width:
          imageMetadata?['width'] as int? ?? videoMetadata?['width'] as int?,
      height:
          imageMetadata?['height'] as int? ?? videoMetadata?['height'] as int?,
      fileSize: int.tryParse('${file['size'] ?? ''}'),
      durationSeconds: videoMetadata != null
          ? ((videoMetadata['durationMillis'] as int?) ?? 0) ~/ 1000
          : null,
      fileHash: file['md5Checksum'] as String?,
      timestamp: timestamp,
    );
  }
}
