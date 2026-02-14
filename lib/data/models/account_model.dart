import '../../core/enums/provider_type.dart';

class AccountModel {
  final String id;
  final ProviderType providerType;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final String accessToken;
  final String? refreshToken;
  final DateTime? tokenExpiry;

  const AccountModel({
    required this.id,
    required this.providerType,
    required this.email,
    this.displayName,
    this.avatarUrl,
    required this.accessToken,
    this.refreshToken,
    this.tokenExpiry,
  });
}
