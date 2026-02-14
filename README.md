# DriveInOne

Unified cloud photo & video gallery with AI-powered face recognition. Connect your Google Drive, OneDrive, and Dropbox accounts and browse all your media in one place, organized by timeline or by the people in your photos.

## Features

- **Multi-Cloud Integration** -- Link Google Drive, OneDrive, and Dropbox accounts and access all media from a single app
- **Unified Timeline** -- Browse photos and videos chronologically across all connected providers
- **AI Face Recognition** -- Automatic face detection, embedding generation, and clustering to group photos by person
- **People View** -- See all recognized individuals and browse their photos
- **Smart Search** -- Search across media metadata from all connected accounts
- **Media Viewer** -- Full-screen photo viewer with zoom and video player
- **Offline-First** -- Local SQLite database keeps your library accessible without a connection
- **Secure Auth** -- OAuth2 authentication with encrypted token storage

## Architecture

The project follows **Clean Architecture** with three layers:

```
lib/
├── core/                  # Constants, enums, errors, theme, utils
├── data/                  # Data layer
│   ├── database/          # Drift (SQLite) tables & DAOs
│   ├── datasources/
│   │   ├── cloud/         # Google Drive, OneDrive, Dropbox providers
│   │   └── local/         # Face detection, embeddings, secure storage
│   ├── models/            # Data models
│   └── repositories/      # Repository implementations
├── domain/                # Business logic (pure Dart)
│   ├── entities/          # Core entities
│   ├── repositories/      # Abstract repository interfaces
│   └── usecases/          # Auth, media, sync, face use cases
├── presentation/          # UI layer
│   ├── providers/         # Riverpod state management
│   ├── screens/           # Splash, home, timeline, people, search, settings, media viewer
│   └── widgets/           # Reusable UI components
├── app.dart               # App configuration
└── main.dart              # Entry point
```

## Tech Stack

| Category | Libraries |
|---|---|
| State Management | Riverpod, Riverpod Generator |
| Routing | Go Router |
| Database | Drift (SQLite) |
| Networking | Dio, Cached Network Image |
| Auth | Google Sign-In, Flutter AppAuth, Flutter Secure Storage |
| AI/ML | Google ML Kit Face Detection, TFLite Flutter |
| Media | Video Player, Chewie, Photo View |
| Code Gen | Freezed, JSON Serializable, Build Runner |

## Getting Started

### Prerequisites

- Flutter >= 3.16.0
- Dart SDK >= 3.2.0

### Setup

```bash
# Clone the repository
git clone https://github.com/vibhorgupta96/DriveInOne.git
cd DriveInOne

# Install dependencies
flutter pub get

# Run code generation (Drift, Freezed, Riverpod, JSON)
dart run build_runner build --delete-conflicting-outputs

# Run the app
flutter run
```

### Cloud Provider Setup

Each cloud provider requires OAuth2 credentials:

1. **Google Drive** -- Create credentials in the [Google Cloud Console](https://console.cloud.google.com/)
2. **OneDrive** -- Register an app in the [Azure Portal](https://portal.azure.com/)
3. **Dropbox** -- Create an app in the [Dropbox App Console](https://www.dropbox.com/developers/apps)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
