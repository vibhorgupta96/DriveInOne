import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;
  final String? error;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.error,
  });

  String get formatted {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final err = error != null ? '\n  ↳ $error' : '';
    return '[$time] $level: $message$err';
  }
}

class AppLogger {
  static const _maxEntries = 200;
  static final _entries = Queue<LogEntry>();
  static final logNotifier = ValueNotifier<int>(0);

  static UnmodifiableListView<LogEntry> get entries =>
      UnmodifiableListView(_entries);

  static void _addEntry(LogEntry entry) {
    _entries.addLast(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    logNotifier.value++;
  }

  static void clearLogs() {
    _entries.clear();
    logNotifier.value++;
  }

  static void info(String message, {String? tag}) {
    developer.log(message, name: tag ?? 'DriveInOne');
    _addEntry(LogEntry(
      timestamp: DateTime.now(),
      level: 'INFO',
      message: message,
    ));
  }

  static void error(String message,
      {Object? error, StackTrace? stackTrace, String? tag}) {
    developer.log(
      message,
      name: tag ?? 'DriveInOne',
      error: error,
      stackTrace: stackTrace,
      level: 1000,
    );
    _addEntry(LogEntry(
      timestamp: DateTime.now(),
      level: 'ERROR',
      message: message,
      error: error?.toString(),
    ));
  }

  static void warning(String message, {String? tag}) {
    developer.log(message, name: tag ?? 'DriveInOne', level: 900);
    _addEntry(LogEntry(
      timestamp: DateTime.now(),
      level: 'WARN',
      message: message,
    ));
  }

  static void debug(String message, {String? tag}) {
    developer.log(message, name: tag ?? 'DriveInOne', level: 500);
    _addEntry(LogEntry(
      timestamp: DateTime.now(),
      level: 'DEBUG',
      message: message,
    ));
  }
}
