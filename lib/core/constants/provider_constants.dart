class ProviderConstants {
  // OAuth identifiers are public application configuration, supplied at build
  // time. OAuth client secrets must never be embedded in a mobile binary.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const String googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );
  static const String googleDriveScope =
      'https://www.googleapis.com/auth/drive.readonly';
  static const String googleDriveBaseUrl =
      'https://www.googleapis.com/drive/v3';

  // Microsoft / OneDrive
  static const String microsoftClientId = String.fromEnvironment(
    'MICROSOFT_CLIENT_ID',
  );
  static const String microsoftRedirectUri =
      'com.driveinone.app://oauth2redirect';
  static const String microsoftDiscoveryUrl =
      'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration';
  static const List<String> microsoftScopes = [
    'Files.Read.All',
    'User.Read',
    'offline_access',
  ];
  static const String graphBaseUrl = 'https://graph.microsoft.com/v1.0';

  // Dropbox
  static const String dropboxAppKey = String.fromEnvironment('DROPBOX_APP_KEY');
  static const String dropboxRedirectUri =
      'com.driveinone.app://oauth2redirect';
  static const String dropboxAuthEndpoint =
      'https://www.dropbox.com/oauth2/authorize';
  static const String dropboxTokenEndpoint =
      'https://api.dropboxapi.com/oauth2/token';
  static const List<String> dropboxScopes = [
    'files.content.read',
    'files.metadata.read',
    'account_info.read',
  ];
  static const String dropboxApiBaseUrl = 'https://api.dropboxapi.com/2';
  static const String dropboxContentBaseUrl =
      'https://content.dropboxapi.com/2';

  static String requireConfigured(String value, String dartDefine) {
    if (value.trim().isEmpty || value.startsWith('YOUR_')) {
      throw StateError(
        'Missing OAuth configuration: pass '
        '--dart-define=$dartDefine=<value>.',
      );
    }
    return value;
  }
}
