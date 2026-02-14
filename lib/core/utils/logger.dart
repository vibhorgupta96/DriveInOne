import 'dart:developer' as developer;

class AppLogger {
  static void info(String message, {String? tag}) {
    developer.log(message, name: tag ?? 'DriveInOne');
  }

  static void error(String message, {Object? error, StackTrace? stackTrace, String? tag}) {
    developer.log(
      message,
      name: tag ?? 'DriveInOne',
      error: error,
      stackTrace: stackTrace,
      level: 1000,
    );
  }

  static void debug(String message, {String? tag}) {
    developer.log(message, name: tag ?? 'DriveInOne', level: 500);
  }
}
