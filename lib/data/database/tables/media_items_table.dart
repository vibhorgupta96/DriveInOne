import 'package:drift/drift.dart';

class MediaItems extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text()();
  TextColumn get remoteId => text()();
  TextColumn get remotePath => text().nullable()();
  TextColumn get fileName => text()();
  TextColumn get mimeType => text()();
  IntColumn get mediaType => intEnum<MediaTypeEnum>()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get fullSizeUrl => text().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get fileSize => integer().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get fileHash => text().nullable()();
  DateTimeColumn get timestamp => dateTime()();
  DateTimeColumn get syncedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  BoolColumn get facesProcessed => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountId, remoteId},
  ];
}

enum MediaTypeEnum {
  photo,
  video,
}
