class ProviderConstants {
  // Google — set via --dart-define or replace with your credentials
  static const String googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: 'YOUR_GOOGLE_WEB_CLIENT_ID.apps.googleusercontent.com');
  static const String googleClientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET', defaultValue: '');
  static const String googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: 'YOUR_GOOGLE_IOS_CLIENT_ID.apps.googleusercontent.com');
  static const String googleDriveScope = 'https://www.googleapis.com/auth/drive.readonly';
  static const String googleDriveBaseUrl = 'https://www.googleapis.com/drive/v3';
  static const String googleTokenEndpoint = 'https://oauth2.googleapis.com/token';

  // Microsoft / OneDrive
  static const String microsoftClientId = 'YOUR_MICROSOFT_CLIENT_ID';
  static const String microsoftRedirectUri = 'com.driveinone.app://oauth2redirect';
  static const String microsoftDiscoveryUrl = 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration';
  static const List<String> microsoftScopes = ['Files.Read.All', 'User.Read', 'offline_access'];
  static const String graphBaseUrl = 'https://graph.microsoft.com/v1.0';

  // Dropbox
  static const String dropboxAppKey = 'YOUR_DROPBOX_APP_KEY';
  static const String dropboxRedirectUri = 'com.driveinone.app://oauth2redirect';
  static const String dropboxAuthEndpoint = 'https://www.dropbox.com/oauth2/authorize';
  static const String dropboxTokenEndpoint = 'https://api.dropboxapi.com/oauth2/token';
  static const List<String> dropboxScopes = ['files.content.read', 'files.metadata.read', 'account_info.read'];
  static const String dropboxApiBaseUrl = 'https://api.dropboxapi.com/2';
  static const String dropboxContentBaseUrl = 'https://content.dropboxapi.com/2';
}
