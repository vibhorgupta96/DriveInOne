import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/logger.dart';
import '../../../data/datasources/local/thumbnail_resolver.dart';
import '../../providers/auth_providers.dart';

final _sharedThumbnailResolver = ThumbnailResolver();

class AuthenticatedImage extends ConsumerStatefulWidget {
  final String? imageUrl;
  final String accountId;
  final String? cacheKey;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Map<String, String>? headers;

  const AuthenticatedImage({
    super.key,
    this.imageUrl,
    required this.accountId,
    this.cacheKey,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.headers,
  });

  @override
  ConsumerState<AuthenticatedImage> createState() => _AuthenticatedImageState();
}

class _AuthenticatedImageState extends ConsumerState<AuthenticatedImage> {
  late Future<Uint8List?> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _resolveImage();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.headers != widget.headers) {
      _imageFuture = _resolveImage();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      return _buildPlaceholder(context);
    }

    return FutureBuilder<Uint8List?>(
      future: _imageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildShimmer(context);
        }
        final bytes = snapshot.data;
        if (snapshot.hasError || bytes == null || bytes.isEmpty) {
          return _buildPlaceholder(context);
        }

        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildPlaceholder(context),
        );
      },
    );
  }

  Future<Uint8List?> _resolveImage() async {
    final imageUrl = widget.imageUrl;
    if (imageUrl == null || imageUrl.isEmpty) return null;

    try {
      final cacheKey = widget.cacheKey ?? '${widget.accountId}|$imageUrl';
      final cached = await _sharedThumbnailResolver.readCached(cacheKey);
      if (cached != null) return cached;

      final headers = <String, String>{...?(widget.headers)};
      if (!headers.containsKey('Authorization')) {
        headers.addAll(
          await ref
              .read(authRepositoryProvider)
              .getAuthHeaders(widget.accountId),
        );
      }
      return _sharedThumbnailResolver.resolve(
        imageUrl,
        headers,
        cacheKey: cacheKey,
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'Thumbnail resolution failed for $imageUrl',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
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
