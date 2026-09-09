import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/constants/provider_constants.dart';
import 'account_operation_gate.dart';

/// Centralized resolution of provider-specific thumbnail URL schemes
/// (`gdrive://thumb/...`, `dropbox://thumbnail...`) into raw image bytes.
///
/// Re-used by the face pipeline, face repository, and authenticated image
/// widget to avoid duplicating the per-provider fetch logic.
class ThumbnailResolver {
  static const _maxMemoryEntries = 100;
  static const _maxDiskEntries = 200;
  static const _maxDiskBytes = 100 * 1024 * 1024;
  static final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};
  // Cache roots are shared by every resolver instance. Serializing mutations
  // keeps global eviction accurate when several accounts finish downloads at
  // once, without taking an account gate while this queue is held.
  static Future<void> _diskMutationTail = Future<void>.value();
  final Dio _dio;
  final Future<Directory> Function() _cacheRoot;

  ThumbnailResolver({Dio? dio, Future<Directory> Function()? cacheRoot})
    : _dio = dio ?? Dio(),
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
    String? accountId,
    int? accountGeneration,
  }) async {
    // Callers supply the explicit account/media/content-revision key. Provider
    // marker URLs are deliberately stable and cannot serve as a revision.
    final versionedKey = cacheKey;
    final resolvedAccountId =
        accountId ??
        (versionedKey == null ? null : _accountFromKey(versionedKey));
    final resolvedGeneration = resolvedAccountId == null
        ? null
        : (accountGeneration ??
              AccountOperationGate.generationFor(resolvedAccountId));
    final cached = versionedKey == null
        ? null
        : await readCached(
            versionedKey,
            accountId: resolvedAccountId,
            accountGeneration: resolvedGeneration,
          );
    if (cached != null) return cached;
    if (resolvedAccountId != null &&
        !AccountOperationGate.isCurrent(
          resolvedAccountId,
          resolvedGeneration!,
        )) {
      return null;
    }

    File? cacheFile;
    if (versionedKey != null && versionedKey.isNotEmpty) {
      try {
        cacheFile = await _cacheFile(
          versionedKey,
          accountId: resolvedAccountId,
        );
      } catch (_) {
        cacheFile = null;
      }
    }

    final bytes = await _download(url, authHeaders);
    if (bytes != null && bytes.isNotEmpty && cacheFile != null) {
      final File targetFile = cacheFile;
      Future<void> commit() => _runDiskMutation(() async {
        try {
          await targetFile.parent.create(recursive: true);
          await targetFile.writeAsBytes(bytes, flush: false);
          await _evictDiskCache();
          _putMemory(versionedKey!, bytes, accountId: resolvedAccountId);
        } catch (_) {
          // Disk caching is opportunistic; the downloaded image is still valid.
        }
      });

      if (resolvedAccountId == null) {
        await commit();
      } else {
        final committed = await AccountOperationGate.runIfCurrent<bool>(
          resolvedAccountId,
          resolvedGeneration!,
          () async {
            await commit();
            return true;
          },
        );
        if (committed != true) return null;
      }
    }
    if (resolvedAccountId != null &&
        !AccountOperationGate.isCurrent(
          resolvedAccountId,
          resolvedGeneration!,
        )) {
      return null;
    }
    return bytes;
  }

  Future<Uint8List?> readCached(
    String cacheKey, {
    String? accountId,
    int? accountGeneration,
  }) async {
    if (cacheKey.isEmpty) return null;
    final resolvedAccountId = accountId ?? _accountFromKey(cacheKey);
    if (resolvedAccountId != null) {
      final generation =
          accountGeneration ??
          AccountOperationGate.generationFor(resolvedAccountId);
      return await AccountOperationGate.runIfCurrent<Uint8List?>(
        resolvedAccountId,
        generation,
        () => _readCachedUnchecked(cacheKey, accountId: resolvedAccountId),
      );
    }
    return _readCachedUnchecked(cacheKey);
  }

  Future<Uint8List?> _readCachedUnchecked(
    String cacheKey, {
    String? accountId,
  }) async {
    final memoryKey = _memoryKey(cacheKey, accountId);
    final memory = _memoryCache.remove(memoryKey);
    if (memory != null) {
      _memoryCache[memoryKey] = memory;
      return memory;
    }
    try {
      final cacheFile = await _cacheFile(cacheKey, accountId: accountId);
      if (!await cacheFile.exists()) return null;
      final bytes = await cacheFile.readAsBytes();
      if (bytes.isEmpty) return null;
      _putMemory(cacheKey, bytes, accountId: accountId);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> purgeAccount(String accountId) async {
    await _runDiskMutation(() async {
      _memoryCache.removeWhere((key, _) => key.startsWith('$accountId\u0000'));
      try {
        final root = await _cacheRoot();
        final directory = Directory(
          p.join(root.path, 'driveinone_thumbnails', _stableHash(accountId)),
        );
        if (await directory.exists()) await directory.delete(recursive: true);
        final legacyRoot = Directory(
          p.join(root.path, 'driveinone_thumbnails'),
        );
        if (await legacyRoot.exists()) {
          // The original flat layout did not encode the account in its file
          // name. Remove these entries during unlink instead of leaving
          // orphaned authenticated previews behind.
          await for (final entity in legacyRoot.list()) {
            if (entity is File && entity.path.endsWith('.img')) {
              await entity.delete();
            }
          }
        }
      } catch (_) {
        // A cache purge must not prevent account cleanup.
      }
    });
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
      options: Options(
        headers: trustedGoogleHeaders(upgradedLink, headers),
        responseType: ResponseType.bytes,
      ),
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

  Future<File> _cacheFile(String cacheKey, {String? accountId}) async {
    final root = await _cacheRoot();
    return File(
      p.join(
        root.path,
        'driveinone_thumbnails',
        _stableHash(accountId ?? _accountFromKey(cacheKey) ?? 'anonymous'),
        '${_stableHash(cacheKey)}.img',
      ),
    );
  }

  Future<void> _evictDiskCache() async {
    try {
      final root = await _cacheRoot();
      final directory = Directory(p.join(root.path, 'driveinone_thumbnails'));
      if (!await directory.exists()) return;
      final files = <File>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) files.add(entity);
      }
      var totalBytes = 0;
      final stats = <File, FileStat>{};
      for (final file in files) {
        final stat = await file.stat();
        stats[file] = stat;
        totalBytes += stat.size;
      }
      files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
      while (files.length > _maxDiskEntries || totalBytes > _maxDiskBytes) {
        final file = files.removeAt(0);
        totalBytes -= stats[file]!.size;
        await file.delete();
      }
    } catch (_) {
      // Cache bounds are opportunistic and must not fail image display.
    }
  }

  static Uint8List? _asBytes(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) return Uint8List.fromList(value.cast<int>());
    return null;
  }

  static void _putMemory(
    String cacheKey,
    Uint8List bytes, {
    String? accountId,
  }) {
    final key = _memoryKey(cacheKey, accountId);
    _memoryCache.remove(key);
    _memoryCache[key] = bytes;
    while (_memoryCache.length > _maxMemoryEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
  }

  static String _memoryKey(String cacheKey, String? accountId) =>
      '${accountId ?? 'anonymous'}\u0000$cacheKey';

  static Future<T> _runDiskMutation<T>(Future<T> Function() action) {
    final previous = _diskMutationTail;
    final completer = Completer<void>();
    _diskMutationTail = completer.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  static String? _accountFromKey(String key) {
    final first = key.indexOf('|');
    if (first <= 0) return null;
    final second = key.indexOf('|', first + 1);
    // Provider account ids are `${provider}|${email}`; cache keys append the
    // media id and revision after that identity.
    return second <= first ? null : key.substring(0, second);
  }

  static Map<String, String> trustedGoogleHeaders(
    String url,
    Map<String, String> headers,
  ) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final trusted =
        uri?.scheme == 'https' &&
        (host == 'googleusercontent.com' ||
            host.endsWith('.googleusercontent.com') ||
            host == 'googleapis.com' ||
            host.endsWith('.googleapis.com'));
    return trusted ? headers : const <String, String>{};
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
