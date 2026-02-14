import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/accounts_table.dart';

part 'accounts_dao.g.dart';

@DriftAccessor(tables: [Accounts])
class AccountsDao extends DatabaseAccessor<AppDatabase>
    with _$AccountsDaoMixin {
  AccountsDao(super.db);

  Future<List<Account>> getAllAccounts() => select(accounts).get();

  Stream<List<Account>> watchAllAccounts() => select(accounts).watch();

  Future<Account?> getAccountById(String id) =>
      (select(accounts)..where((a) => a.id.equals(id))).getSingleOrNull();

  Future<List<Account>> getAccountsByProvider(ProviderTypeEnum type) =>
      (select(accounts)..where((a) => a.providerType.equalsValue(type))).get();

  Future<void> insertAccount(AccountsCompanion account) =>
      into(accounts).insert(account, mode: InsertMode.insertOrReplace);

  Future<void> updateAccount(AccountsCompanion account) =>
      (update(accounts)..where((a) => a.id.equals(account.id.value)))
          .write(account);

  Future<void> deleteAccount(String id) =>
      (delete(accounts)..where((a) => a.id.equals(id))).go();

  Future<void> updateSyncToken(String id, String? token) =>
      (update(accounts)..where((a) => a.id.equals(id)))
          .write(AccountsCompanion(syncToken: Value(token)));

  Future<void> updateTokenExpiry(String id, DateTime? expiry) =>
      (update(accounts)..where((a) => a.id.equals(id)))
          .write(AccountsCompanion(tokenExpiry: Value(expiry)));
}
