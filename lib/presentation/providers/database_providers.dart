import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database/app_database.dart';
import '../../data/datasources/local/secure_storage_source.dart';

final secureStorageProvider = Provider<SecureStorageSource>((ref) {
  return SecureStorageSource();
});

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('Must be overridden in ProviderScope');
});
