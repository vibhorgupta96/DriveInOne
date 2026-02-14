import '../../repositories/sync_repository.dart';

class SyncSingleAccount {
  final SyncRepository _repository;

  const SyncSingleAccount(this._repository);

  Future<void> call(String accountId) => _repository.syncAccount(accountId);
}
