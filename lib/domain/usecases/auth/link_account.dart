import '../../../core/enums/provider_type.dart';
import '../../entities/account.dart';
import '../../repositories/auth_repository.dart';

class LinkAccount {
  final AuthRepository _repository;

  const LinkAccount(this._repository);

  Future<AccountEntity> call(ProviderType type) => _repository.linkAccount(type);
}
