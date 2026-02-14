import '../entities/sync_status.dart';

abstract class SyncRepository {
  Future<void> syncAccount(String accountId);
  Future<void> syncAllAccounts();
  Stream<SyncStatus> watchSyncStatus();
}
