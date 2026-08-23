import 'package:drift/drift.dart';

class Faces extends Table {
  TextColumn get id => text()();
  TextColumn get mediaItemId => text()();
  TextColumn get boundingBox =>
      text()(); // JSON: {"left":0,"top":0,"width":100,"height":100}
  BlobColumn get embedding => blob()(); // 192-dim float32 = 768 bytes
  TextColumn get clusterId => text().nullable()();
  DateTimeColumn get detectedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
