import '../../entities/account.dart';
import '../../repositories/auth_repository.dart';

class GetLinkedAccounts {
  final AuthRepository _repository;

  const GetLinkedAccounts(this._repository);

  Stream<List<AccountEntity>> call() => _repository.watchLinkedAccounts();
}
