import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/utils/logger.dart';
import 'data/database/app_database.dart';
import 'presentation/providers/database_providers.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AppLogger.error(
          'Flutter framework error: ${details.exceptionAsString()}',
          error: details.exception,
          stackTrace: details.stack,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        AppLogger.error('Unhandled platform error',
            error: error, stackTrace: stack);
        return true;
      };

      final database = await constructDb();

      runApp(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
          ],
          child: const DriveInOneApp(),
        ),
      );
    },
    (error, stack) {
      AppLogger.error('Unhandled zone error', error: error, stackTrace: stack);
    },
  );
}
