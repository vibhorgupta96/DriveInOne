import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../core/constants/app_constants.dart';
import 'tables/accounts_table.dart';
import 'tables/media_items_table.dart';
import 'tables/faces_table.dart';
import 'tables/face_clusters_table.dart';
import 'daos/accounts_dao.dart';
import 'daos/media_items_dao.dart';
import 'daos/faces_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Accounts, MediaItems, Faces, FaceClusters],
  daos: [AccountsDao, MediaItemsDao, FacesDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Future migrations
        },
      );
}

Future<AppDatabase> constructDb() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, AppConstants.dbName));
  return AppDatabase(NativeDatabase.createInBackground(file));
}
