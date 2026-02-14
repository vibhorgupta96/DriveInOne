import '../../repositories/auth_repository.dart';

class UnlinkAccount {
  final AuthRepository _repository;

  const UnlinkAccount(this._repository);

  Future<void> call(String accountId) => _repository.unlinkAccount(accountId);
}
