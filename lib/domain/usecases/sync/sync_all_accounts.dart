import '../../repositories/sync_repository.dart';

class SyncAllAccounts {
  final SyncRepository _repository;

  const SyncAllAccounts(this._repository);

  Future<void> call() => _repository.syncAllAccounts();
}
