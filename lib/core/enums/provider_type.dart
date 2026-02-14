enum ProviderType {
  google,
  onedrive,
  dropbox;

  String get displayName {
    switch (this) {
      case ProviderType.google:
        return 'Google Drive';
      case ProviderType.onedrive:
        return 'OneDrive';
      case ProviderType.dropbox:
        return 'Dropbox';
    }
  }

  String get iconAsset {
    switch (this) {
      case ProviderType.google:
        return 'assets/images/google_drive.png';
      case ProviderType.onedrive:
        return 'assets/images/onedrive.png';
      case ProviderType.dropbox:
        return 'assets/images/dropbox.png';
    }
  }
}
