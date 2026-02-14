class AppConstants {
  static const String appName = 'DriveInOne';
  static const String dbName = 'drive_in_one.sqlite';
  static const int syncPageSize = 100;
  static const int timelinePageSize = 50;
  static const int faceBatchSize = 20;
  static const Duration httpTimeout = Duration(seconds: 30);
  static const Duration tokenRefreshBuffer = Duration(minutes: 5);
  static const double faceSimilarityThreshold = 0.65;
  static const int faceEmbeddingDimension = 192;
  static const int faceInputSize = 112;
}
