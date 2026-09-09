import 'package:equatable/equatable.dart';

class SyncStatus extends Equatable {
  final bool isSyncing;
  final String? currentAccountId;
  final int itemsSynced;
  final int totalItems;
  final String? error;
  final DateTime? lastSyncTime;

  const SyncStatus({
    this.isSyncing = false,
    this.currentAccountId,
    this.itemsSynced = 0,
    this.totalItems = 0,
    this.error,
    this.lastSyncTime,
  });

  const SyncStatus.idle({DateTime? lastSync})
    : isSyncing = false,
      currentAccountId = null,
      itemsSynced = 0,
      totalItems = 0,
      error = null,
      lastSyncTime = lastSync;

  const SyncStatus.syncing({
    required String accountId,
    int synced = 0,
    int total = 0,
  }) : isSyncing = true,
       currentAccountId = accountId,
       itemsSynced = synced,
       totalItems = total,
       error = null,
       lastSyncTime = null;

  const SyncStatus.error(String errorMessage)
    : isSyncing = false,
      currentAccountId = null,
      itemsSynced = 0,
      totalItems = 0,
      error = errorMessage,
      lastSyncTime = null;

  @override
  List<Object?> get props => [isSyncing, currentAccountId, itemsSynced, error];
}
