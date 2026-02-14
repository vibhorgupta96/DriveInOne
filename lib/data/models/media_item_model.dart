import '../../core/enums/media_type.dart';

class MediaItemModel {
  final String remoteId;
  final String? remotePath;
  final String fileName;
  final String mimeType;
  final MediaType mediaType;
  final String? thumbnailUrl;
  final String? fullSizeUrl;
  final int? width;
  final int? height;
  final int? fileSize;
  final int? durationSeconds;
  final String? fileHash;
  final DateTime timestamp;

  const MediaItemModel({
    required this.remoteId,
    this.remotePath,
    required this.fileName,
    required this.mimeType,
    required this.mediaType,
    this.thumbnailUrl,
    this.fullSizeUrl,
    this.width,
    this.height,
    this.fileSize,
    this.durationSeconds,
    this.fileHash,
    required this.timestamp,
  });

  static MediaType mediaTypeFromMime(String mimeType) {
    if (mimeType.startsWith('video/')) return MediaType.video;
    return MediaType.photo;
  }
}
