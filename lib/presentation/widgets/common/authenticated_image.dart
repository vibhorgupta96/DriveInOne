import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class AuthenticatedImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return _buildPlaceholder(context);
    }

    // Skip special URLs (like dropbox:// scheme)
    if (imageUrl!.startsWith('dropbox://')) {
      return _buildPlaceholder(context);
    }

    return CachedNetworkImage(
      imageUrl: imageUrl!,
      width: width,
      height: height,
      fit: fit,
      httpHeaders: headers ?? const {},
      placeholder: (_, __) => _buildShimmer(context),
      errorWidget: (_, __, ___) => _buildPlaceholder(context),
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
