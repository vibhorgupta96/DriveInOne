import 'package:equatable/equatable.dart';
import '../../core/enums/provider_type.dart';

class AccountEntity extends Equatable {
  final String id;
  final ProviderType providerType;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final String? syncToken;
  final DateTime? tokenExpiry;
  final DateTime createdAt;

  const AccountEntity({
    required this.id,
    required this.providerType,
    required this.email,
    this.displayName,
    this.avatarUrl,
    this.syncToken,
    this.tokenExpiry,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [id, providerType, email];
}
