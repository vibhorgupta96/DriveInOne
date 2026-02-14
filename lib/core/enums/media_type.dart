enum MediaType {
  photo,
  video;

  String get displayName {
    switch (this) {
      case MediaType.photo:
        return 'Photo';
      case MediaType.video:
        return 'Video';
    }
  }
}
