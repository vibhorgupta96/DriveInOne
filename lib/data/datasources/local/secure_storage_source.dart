import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageSource {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Token storage
  Future<void> saveTokens({
    required String accountId,
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) async {
    await _storage.write(key: '${accountId}_access_token', value: accessToken);
    if (refreshToken != null) {
      await _storage.write(key: '${accountId}_refresh_token', value: refreshToken);
    }
    if (expiry != null) {
      await _storage.write(
        key: '${accountId}_token_expiry',
        value: expiry.toIso8601String(),
      );
    }
  }

  Future<String?> getAccessToken(String accountId) async {
    return await _storage.read(key: '${accountId}_access_token');
  }

  Future<String?> getRefreshToken(String accountId) async {
    return await _storage.read(key: '${accountId}_refresh_token');
  }

  Future<DateTime?> getTokenExpiry(String accountId) async {
    final expiryStr = await _storage.read(key: '${accountId}_token_expiry');
    if (expiryStr == null) return null;
    return DateTime.tryParse(expiryStr);
  }

  Future<void> deleteTokens(String accountId) async {
    await _storage.delete(key: '${accountId}_access_token');
    await _storage.delete(key: '${accountId}_refresh_token');
    await _storage.delete(key: '${accountId}_token_expiry');
  }

  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }
}
