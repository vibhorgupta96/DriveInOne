import '../entities/sync_status.dart';

class AccountSyncOutcome {
  final String accountId;
  final String accountLabel;
  final int itemsSynced;
  final int itemsDeleted;
  final String? errorMessage;

  const AccountSyncOutcome({
    required this.accountId,
    required this.accountLabel,
    required this.itemsSynced,
    required this.itemsDeleted,
    this.errorMessage,
  });

  const AccountSyncOutcome.success({
    required this.accountId,
    required this.accountLabel,
    required this.itemsSynced,
    required this.itemsDeleted,
  }) : errorMessage = null;

  const AccountSyncOutcome.failure({
    required this.accountId,
    required this.accountLabel,
    required String error,
  })  : itemsSynced = 0,
        itemsDeleted = 0,
        errorMessage = error;

  bool get succeeded => errorMessage == null;
}

class SyncResult {
  final int itemsSynced;
  final int itemsDeleted;
  final List<AccountSyncOutcome> accountOutcomes;

  const SyncResult({
    required this.itemsSynced,
    required this.itemsDeleted,
    this.accountOutcomes = const [],
  });

  List<AccountSyncOutcome> get successfulAccounts =>
      accountOutcomes.where((outcome) => outcome.succeeded).toList();

  List<AccountSyncOutcome> get failedAccounts =>
      accountOutcomes.where((outcome) => !outcome.succeeded).toList();

  bool get hasFailures => failedAccounts.isNotEmpty;
  bool get hasSuccessfulAccounts => successfulAccounts.isNotEmpty;
  bool get isPartialSuccess => hasFailures && hasSuccessfulAccounts;
  bool get allFailed => hasFailures && !hasSuccessfulAccounts;
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
