# MediaTube

<p align="center">
  <img src="assets/icon.png" width="120" alt="MediaTube Logo">
</p>

# ⚠️ Legal Disclaimer

**This application is for educational purposes only.** 

1. **Personal Use Only**: Do not use this tool to distribute copyrighted content.
2. **Respect Terms of Service**: You must comply with the ToS of any platform (YouTube, Instagram, etc.) you access.
3. **Anti-Piracy**: This app is protected by signature verification. **Do not clone, re-upload, or sell this application.** Any modified versions may not function correctly.
4. **No Warranties**: The developers are not responsible for any misuse or damages caused by this software.

---

# MediaTube

A Flutter Android app with browser and media downloading capabilities. Download videos from YouTube and other websites.

## Features

- 🌐 **Built-in Browser** - Navigate to any website using embedded WebView
- 🎬 **YouTube Support** - Download YouTube videos in various qualities (up to 1080p+)
- 📥 **Media Detection** - Automatically detects downloadable media from websites
- 🚀 **Faster Social Extraction** - Improved Facebook/Instagram/TikTok/X share normalization and media detection
- 📏 **Better Size Accuracy** - Uses explicit size hints and concurrent probe workers for more reliable file size estimates
- 📊 **Download Manager** - Track progress, pause/resume downloads
- 🔔 **Process Notifications** - Download, scan, and playback state notifications
- 🔄 **Auto-Update** - Check for app updates automatically
- 🎵 **Audio Extraction** - Download audio-only streams from videos
- 🎧 **YouTube Background Playback** - Play YouTube audio/video streams in background mode with screen-off continuity

## Screenshots

<!-- Add screenshots here -->
| Browser | Download Options | Downloads |
|---------|-----------------|-----------|
| ![Browser](screenshots/browser.png) | ![Options](screenshots/options.png) | ![Downloads](screenshots/downloads.png) |

## Requirements

- Android 6.0 (API 23) or higher
- Java Backend Server (for YouTube downloads)

## Installation

### Option 1: Download APK
Download the latest APK from [Releases](https://github.com/rajeshbsws557/MediaTube/releases).

### Option 2: Build from Source

1. **Clone the repository**
   ```bash
   git clone https://github.com/rajeshbsws557/MediaTube.git
   cd MediaTube
   ```

2. **Configure the app**
   
   Edit `lib/config/app_config.dart` with your server URL:
   ```dart
   static const String backendBaseUrl = 'http://YOUR_SERVER_IP:5000';
   ```

3. **Install dependencies**
   ```bash
   flutter pub get
   ```

4. **Run the app**
   ```bash
   flutter run
   ```

5. **Build release APK**
   ```bash
   flutter build apk --release
   ```

## Backend Server

MediaTube uses on-device extraction by default and can optionally fall back to a backend server.

## Configuration

All configurable values are in `lib/config/app_config.dart`:

| Setting | Description |
|---------|-------------|
| `backendBaseUrl` | URL of your Java backend server |
| `githubReleasesUrl` | GitHub releases URL for auto-updates |

## Architecture

```
lib/
├── config/           # App configuration
├── models/           # Data models
├── providers/        # State management (Provider)
├── screens/          # UI screens
├── services/         # Business logic
└── widgets/          # Reusable UI components
```

## Tech Stack

- **Framework**: Flutter
- **Language**: Dart
- **State Management**: Provider
- **HTTP Client**: Dio
- **WebView**: flutter_inappwebview
- **Video Processing**: FFmpeg

## Permissions

| Permission | Purpose |
|------------|---------|
| `INTERNET` | Network access |
| `WRITE_EXTERNAL_STORAGE` | Save downloads |
| `READ_EXTERNAL_STORAGE` | Access saved files |
| `REQUEST_INSTALL_PACKAGES` | App updates |
| `POST_NOTIFICATIONS` | Download notifications |

## Building for Release

```bash
flutter build apk --release
```

The APK will be at `build/app/outputs/flutter-apk/app-release.apk`

## GitHub Split-ABI Release

Tag pushes (`v*`) trigger `.github/workflows/release.yml` and publish split APK assets:

- `app-arm64-v8a-release.apk`
- `app-armeabi-v7a-release.apk`
- `app-universal-release.apk` (fallback)

Release flow:

```bash
git add -A
git commit -m "release: vX.Y.Z"
git push origin master
git tag vX.Y.Z
git push origin vX.Y.Z
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

Copyright (c) 2026 Rajesh Biswas. All Rights Reserved.

This application and its source code are the proprietary property of Rajesh Biswas. You may not use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software without explicit prior written permission from the author.

## Disclaimer

This app is for personal use only. Respect copyright laws and the terms of service of websites you visit. The developers are not responsible for any misuse of this application. **Copying or modifying the source code is strictly prohibited.**

## Acknowledgments

- [NewPipe Extractor](https://github.com/TeamNewPipe/NewPipeExtractor) - YouTube extraction
- [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) - WebView implementation
- [FFmpeg](https://ffmpeg.org/) - Video processing
