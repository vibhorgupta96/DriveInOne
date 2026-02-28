class AppConstants {
  static const String appName = 'DriveInOne';
  static const String dbName = 'drive_in_one.sqlite';
  static const int syncPageSize = 100;
  static const int timelinePageSize = 50;
  static const int faceBatchSize = 20;
  static const Duration httpTimeout = Duration(seconds: 30);
  static const Duration tokenRefreshBuffer = Duration(minutes: 5);
  static const double faceSimilarityThreshold = 0.55;
  static const int faceEmbeddingDimension = 192;
  static const int faceInputSize = 112;

  /// Extra margin around the ML Kit bounding box before cropping.
  /// 0.4 = 40 % of the face width/height added on each side.
  static const double facePaddingRatio = 0.4;

  /// Faces smaller than this (in pixels, on the longer side) are skipped.
  static const int minFaceSizePixels = 48;

  /// Maximum absolute head-rotation (Y-axis, left/right) in degrees.
  /// Profile faces beyond this are skipped.
  static const double maxHeadEulerAngleY = 36.0;

  /// Maximum absolute head-tilt (Z-axis) in degrees.
  static const double maxHeadEulerAngleZ = 30.0;
}
