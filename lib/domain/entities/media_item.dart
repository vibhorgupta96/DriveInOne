import 'package:equatable/equatable.dart';
import '../../core/enums/media_type.dart';

class MediaItemEntity extends Equatable {
  final String id;
  final String accountId;
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
  final DateTime syncedAt;
  final bool facesProcessed;

  const MediaItemEntity({
    required this.id,
    required this.accountId,
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
    required this.syncedAt,
    this.facesProcessed = false,
  });

  String get formattedDuration {
    if (durationSeconds == null) return '';
    final minutes = durationSeconds! ~/ 60;
    final seconds = durationSeconds! % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String get formattedFileSize {
    if (fileSize == null) return '';
    if (fileSize! < 1024) return '${fileSize}B';
    if (fileSize! < 1024 * 1024) return '${(fileSize! / 1024).toStringAsFixed(1)}KB';
    if (fileSize! < 1024 * 1024 * 1024) {
      return '${(fileSize! / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(fileSize! / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  @override
  List<Object?> get props => [id, accountId, remoteId];
}
