import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'data/database/app_database.dart';
import 'presentation/providers/database_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = await constructDb();

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
      ],
      child: const DriveInOneApp(),
    ),
  );
}
