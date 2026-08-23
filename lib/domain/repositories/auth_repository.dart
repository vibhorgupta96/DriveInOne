import '../../core/enums/provider_type.dart';
import '../entities/account.dart';
import '../entities/media_item.dart';
import '../entities/resolved_media.dart';

abstract class AuthRepository {
  Future<AccountEntity> linkAccount(ProviderType type);
  Future<void> unlinkAccount(String accountId);
  Future<List<AccountEntity>> getLinkedAccounts();
  Stream<List<AccountEntity>> watchLinkedAccounts();
  Future<Map<String, String>> getAuthHeaders(String accountId);
  Future<ResolvedMedia> resolveMedia(MediaItemEntity mediaItem);
  Future<void> refreshToken(String accountId);
}
