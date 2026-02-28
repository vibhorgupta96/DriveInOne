import '../../../core/enums/provider_type.dart';
import '../../models/account_model.dart';
import '../../models/sync_result_model.dart';

abstract class CloudProvider {
  String get providerId;
  ProviderType get providerType;

  Future<AccountModel> login();
  Future<void> logout();
  Future<SyncResultModel> scanDelta(String? syncToken);
  Future<Map<String, String>> getAuthHeaders();
  Future<String> getVideoStreamUrl(String fileId);
  Future<String> getThumbnailUrl(String fileId);
  Future<void> refreshTokenIfNeeded({bool force = false});

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  DateTime? get tokenExpiry => _tokenExpiry;

  bool get isTokenExpired {
    if (_tokenExpiry == null) return true;
    return DateTime.now().isAfter(
      _tokenExpiry!.subtract(const Duration(minutes: 5)),
    );
  }

  void setTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) {
    _accessToken = accessToken;
    if (refreshToken != null) _refreshToken = refreshToken;
    if (expiry != null) _tokenExpiry = expiry;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
  }
}
