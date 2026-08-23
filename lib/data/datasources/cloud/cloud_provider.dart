import '../../../core/constants/app_constants.dart';
import '../../../core/enums/provider_type.dart';
import '../../models/account_model.dart';
import '../../models/sync_result_model.dart';

/// Token state management shared by all cloud providers.
mixin TokenManagement {
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  DateTime? get tokenExpiry => _tokenExpiry;

  bool get isTokenExpired {
    if (_tokenExpiry == null) return true;
    return DateTime.now().isAfter(
      _tokenExpiry!.subtract(AppConstants.tokenRefreshBuffer),
    );
  }

  void setTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) {
    _accessToken = accessToken;
    // Null is meaningful when restoring an account. Always replace every
    // field so credentials from a previous session cannot leak into this one.
    _refreshToken = refreshToken;
    _tokenExpiry = expiry;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
  }
}

/// Creates a fresh provider session for one account operation.
///
/// [accountId] is null only while starting an explicit link flow.
typedef CloudProviderFactory = CloudProvider Function({String? accountId});

abstract class CloudProvider with TokenManagement {
  String get providerId;
  ProviderType get providerType;

  Future<AccountModel> login();
  Future<void> logout();
  Future<SyncResultModel> scanDelta(String? syncToken);
  Future<Map<String, String>> getAuthHeaders();
  Future<String> getVideoStreamUrl(String fileId);
  Future<String> getThumbnailUrl(String fileId);
  Future<void> refreshTokenIfNeeded({bool force = false});
}
