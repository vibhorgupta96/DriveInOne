import 'dart:convert';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../core/constants/provider_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/datasources/local/secure_storage_source.dart';

class AuthenticatedImage extends StatefulWidget {
  final String? imageUrl;
  final String accountId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Map<String, String>? headers;

  const AuthenticatedImage({
    super.key,
    this.imageUrl,
    required this.accountId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.headers,
  });

  @override
  State<AuthenticatedImage> createState() => _AuthenticatedImageState();
}

class _AuthenticatedImageState extends State<AuthenticatedImage> {
  final SecureStorageSource _secureStorage = SecureStorageSource();
  final Dio _dio = Dio();
  late Future<_ResolvedImage?> _resolvedImageFuture;

  @override
  void initState() {
    super.initState();
    _resolvedImageFuture = _resolveImage();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.headers != widget.headers) {
      _resolvedImageFuture = _resolveImage();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      return _buildPlaceholder(context);
    }

    return FutureBuilder<_ResolvedImage?>(
      future: _resolvedImageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildShimmer(context);
        }
        if (snapshot.hasError || !snapshot.hasData || snapshot.data == null) {
          return _buildPlaceholder(context);
        }

        final resolved = snapshot.data!;
        if (resolved.bytes != null) {
          return Image.memory(
            resolved.bytes!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _buildPlaceholder(context),
          );
        }

        return CachedNetworkImage(
          imageUrl: resolved.url!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          httpHeaders: resolved.headers,
          placeholder: (_, __) => _buildShimmer(context),
          errorWidget: (_, __, ___) => _buildPlaceholder(context),
        );
      },
    );
  }

  Future<_ResolvedImage?> _resolveImage() async {
    final imageUrl = widget.imageUrl;
    if (imageUrl == null || imageUrl.isEmpty) return null;

    try {
      if (imageUrl.startsWith('gdrive://thumb/')) {
        final bytes = await _fetchGoogleDriveThumb(imageUrl);
        return bytes != null ? _ResolvedImage.fromBytes(bytes) : null;
      }

      if (imageUrl.startsWith('dropbox://thumbnail')) {
        final bytes = await _fetchDropboxThumb(imageUrl);
        return bytes != null ? _ResolvedImage.fromBytes(bytes) : null;
      }

      final headers = await _buildAuthHeadersForUrl(imageUrl);
      return _ResolvedImage.fromNetwork(imageUrl, headers: headers);
    } catch (e) {
      AppLogger.error('AuthenticatedImage resolve failed for $imageUrl', error: e);
      return null;
    }
  }

  Future<Map<String, String>> _buildAuthHeadersForUrl(String imageUrl) async {
    final merged = <String, String>{...?(widget.headers)};
    final needsAuth = widget.accountId.startsWith('google|') ||
        widget.accountId.startsWith('onedrive|') ||
        widget.accountId.startsWith('dropbox|') ||
        imageUrl.contains('graph.microsoft.com');

    if (needsAuth && !merged.containsKey('Authorization')) {
      final token = await _secureStorage.getAccessToken(widget.accountId);
      if (token != null && token.isNotEmpty) {
        merged['Authorization'] = 'Bearer $token';
      }
    }
    return merged;
  }

  Future<Uint8List?> _fetchGoogleDriveThumb(String url) async {
    final token = await _secureStorage.getAccessToken(widget.accountId);
    if (token == null || token.isEmpty) return null;

    final fileId = url.replaceFirst('gdrive://thumb/', '');
    final metaResponse = await _dio.get(
      '${ProviderConstants.googleDriveBaseUrl}/files/$fileId',
      queryParameters: const {'fields': 'thumbnailLink'},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );

    final freshLink = metaResponse.data['thumbnailLink'] as String?;
    if (freshLink == null || freshLink.isEmpty) return null;

    final upgradedLink = freshLink.replaceFirst(RegExp(r'=s\d+'), '=s800');
    final thumbResponse = await _dio.get(
      upgradedLink,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(List<int>.from(thumbResponse.data as List));
  }

  Future<Uint8List?> _fetchDropboxThumb(String url) async {
    final token = await _secureStorage.getAccessToken(widget.accountId);
    if (token == null || token.isEmpty) return null;

    final path = url.replaceFirst('dropbox://thumbnail', '');
    final apiArg = jsonEncode({
      'resource': {'.tag': 'path', 'path': path},
      'format': 'jpeg',
      'size': 'w256h256',
    });

    final response = await _dio.post(
      '${ProviderConstants.dropboxContentBaseUrl}/files/get_thumbnail_v2',
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': apiArg,
        },
        responseType: ResponseType.bytes,
      ),
    );
    return Uint8List.fromList(List<int>.from(response.data as List));
  }

  Widget _buildShimmer(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

class _ResolvedImage {
  final String? url;
  final Uint8List? bytes;
  final Map<String, String> headers;

  const _ResolvedImage._({
    this.url,
    this.bytes,
    this.headers = const {},
  });

  factory _ResolvedImage.fromNetwork(String url, {Map<String, String> headers = const {}}) {
    return _ResolvedImage._(url: url, headers: headers);
  }

  factory _ResolvedImage.fromBytes(Uint8List bytes) {
    return _ResolvedImage._(bytes: bytes);
  }
}
