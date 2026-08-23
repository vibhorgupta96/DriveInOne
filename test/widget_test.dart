import 'package:drift/native.dart';
import 'package:drive_in_one/app.dart';
import 'package:drive_in_one/data/database/app_database.dart';
import 'package:drive_in_one/presentation/providers/database_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new users are routed from splash to account setup',
      (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
          child: const DriveInOneApp(),
        ),
      );

      expect(find.text('DriveInOne'), findsOneWidget);
      expect(find.text('All your cloud photos, one gallery'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
      expect(find.text('Link Google Drive'), findsOneWidget);
      expect(find.text('Link OneDrive'), findsOneWidget);
      expect(find.text('Link Dropbox'), findsOneWidget);
    } finally {
      // Unmount Riverpod and drain Drift's zero-delay stream cleanup timer.
      // The in-memory executor is then reclaimed with this isolated test
      // process; closing it while the fake clock is paused can deadlock.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
