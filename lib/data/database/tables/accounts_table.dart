import 'package:drift/drift.dart';

class Accounts extends Table {
  TextColumn get id => text()();
  IntColumn get providerType => intEnum<ProviderTypeEnum>()();
  TextColumn get email => text()();
  TextColumn get displayName => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get syncToken => text().nullable()();
  DateTimeColumn get tokenExpiry => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// Drift requires its own enum - maps to ProviderType
enum ProviderTypeEnum {
  google,
  onedrive,
  dropbox,
}
