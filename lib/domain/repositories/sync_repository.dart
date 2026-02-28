import '../entities/sync_status.dart';

class SyncResult {
  final int itemsSynced;
  final int itemsDeleted;
  SyncResult({required this.itemsSynced, required this.itemsDeleted});
}

abstract class SyncRepository {
  Future<SyncResult> syncAccount(String accountId);
  Future<SyncResult> syncAllAccounts();
  Stream<SyncStatus> watchSyncStatus();
  /// Refreshes stored tokens for all linked accounts.
  /// When [silentOnly] is true, providers that may show interactive UI
  /// (e.g. Google Sign-In) are skipped — only pure OAuth token-endpoint
  /// refreshes (Dropbox, OneDrive) are performed.
  Future<void> refreshAllTokens({bool silentOnly = false});
}
