import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/constants/provider_constants.dart';

/// Centralized resolution of provider-specific thumbnail URL schemes
/// (`gdrive://thumb/...`, `dropbox://thumbnail...`) into raw image bytes.
///
/// Re-used by the face pipeline, face repository, and authenticated image
/// widget to avoid duplicating the per-provider fetch logic.
class ThumbnailResolver {
  final Dio _dio;
  final Future<Directory> Function() _cacheRoot;

  ThumbnailResolver({
    Dio? dio,
    Future<Directory> Function()? cacheRoot,
  })  : _dio = dio ?? Dio(),
        _cacheRoot = cacheRoot ?? getTemporaryDirectory;

  /// Constructs a stable thumbnail URL for items that may not have one stored.
  static String? constructThumbnailUrl({
    required String accountId,
    required String remoteId,
    String? remotePath,
  }) {
    if (accountId.startsWith('dropbox|') &&
        remotePath != null &&
        remotePath.isNotEmpty) {
      return 'dropbox://thumbnail$remotePath';
    }
    if (accountId.startsWith('onedrive|')) {
      return '${ProviderConstants.graphBaseUrl}/me/drive/items/$remoteId/thumbnails/0/large/content';
    }
    if (accountId.startsWith('google|')) {
      return 'gdrive://thumb/$remoteId';
    }
    return null;
  }

  /// Downloads thumbnail bytes for the given [url] using the supplied [authHeaders].
  /// Returns `null` if the thumbnail cannot be fetched.
  Future<Uint8List?> resolve(
    String url,
    Map<String, String> authHeaders, {
    String? cacheKey,
  }) async {
    final cached = cacheKey == null ? null : await readCached(cacheKey);
    if (cached != null) return cached;

    File? cacheFile;
    if (cacheKey != null && cacheKey.isNotEmpty) {
      try {
        cacheFile = await _cacheFile(cacheKey);
      } catch (_) {
        cacheFile = null;
      }
    }

    final bytes = await _download(url, authHeaders);
    if (bytes != null && bytes.isNotEmpty && cacheFile != null) {
      try {
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsBytes(bytes, flush: false);
      } catch (_) {
        // Disk caching is opportunistic; the downloaded image is still valid.
      }
    }
    return bytes;
  }

  Future<Uint8List?> readCached(String cacheKey) async {
    if (cacheKey.isEmpty) return null;
    try {
      final cacheFile = await _cacheFile(cacheKey);
      if (!await cacheFile.exists()) return null;
      final bytes = await cacheFile.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _download(
    String url,
    Map<String, String> authHeaders,
  ) async {
    if (url.startsWith('gdrive://thumb/')) {
      return _resolveGDrive(url, authHeaders);
    }
    if (url.startsWith('dropbox://thumbnail')) {
      return _resolveDropbox(url, authHeaders);
    }
    final response = await _dio.get(
      url,
      options: Options(headers: authHeaders, responseType: ResponseType.bytes),
    );
    return _asBytes(response.data);
  }

  Future<Uint8List?> _resolveGDrive(
    String url,
    Map<String, String> headers,
  ) async {
    final fileId = url.replaceFirst('gdrive://thumb/', '');
    final metaResponse = await _dio.get(
      '${ProviderConstants.googleDriveBaseUrl}/files/$fileId',
      queryParameters: const {'fields': 'thumbnailLink'},
      options: Options(headers: headers),
    );
    final freshLink = metaResponse.data['thumbnailLink'] as String?;
    if (freshLink == null || freshLink.isEmpty) return null;

    final upgradedLink = freshLink.replaceFirst(RegExp(r'=s\d+'), '=s800');
    final thumbResponse = await _dio.get(
      upgradedLink,
      options: Options(responseType: ResponseType.bytes),
    );
    return _asBytes(thumbResponse.data);
  }

  Future<Uint8List?> _resolveDropbox(
    String url,
    Map<String, String> headers,
  ) async {
    final path = url.replaceFirst('dropbox://thumbnail', '');
    final apiArg = jsonEncode({
      'resource': {'.tag': 'path', 'path': path},
      'format': 'jpeg',
      'size': 'w640h480',
    });
    final response = await _dio.post(
      '${ProviderConstants.dropboxContentBaseUrl}/files/get_thumbnail_v2',
      options: Options(
        headers: {...headers, 'Dropbox-API-Arg': apiArg},
        responseType: ResponseType.bytes,
      ),
    );
    return _asBytes(response.data);
  }

  Future<File> _cacheFile(String cacheKey) async {
    final root = await _cacheRoot();
    return File(
      p.join(
          root.path, 'driveinone_thumbnails', '${_stableHash(cacheKey)}.img'),
    );
  }

  static Uint8List? _asBytes(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) return Uint8List.fromList(value.cast<int>());
    return null;
  }

  // FNV-1a produces a compact, filesystem-safe deterministic cache name
  // without depending on a transitive hashing package.
  static String _stableHash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
