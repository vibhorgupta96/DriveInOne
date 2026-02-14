import '../../core/enums/provider_type.dart';
import '../entities/account.dart';

abstract class AuthRepository {
  Future<AccountEntity> linkAccount(ProviderType type);
  Future<void> unlinkAccount(String accountId);
  Future<List<AccountEntity>> getLinkedAccounts();
  Stream<List<AccountEntity>> watchLinkedAccounts();
  Future<Map<String, String>> getAuthHeaders(String accountId);
  Future<void> refreshToken(String accountId);
}
