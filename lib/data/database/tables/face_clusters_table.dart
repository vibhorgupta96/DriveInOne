import 'package:drift/drift.dart';

class FaceClusters extends Table {
  TextColumn get id => text()();
  TextColumn get label => text().nullable()();
  TextColumn get representativeFaceId => text().nullable()();
  BlobColumn get centroidEmbedding => blob().nullable()();
  IntColumn get faceCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
