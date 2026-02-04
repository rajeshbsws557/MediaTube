# MediaTube - Copilot Instructions

## Project Overview
MediaTube is a Flutter Android app that functions as a browser with media detection and downloading capabilities.

## Tech Stack
- **Framework**: Flutter (Android only)
- **Language**: Dart
- **State Management**: Provider
- **Key Packages**: 
  - flutter_inappwebview (browser)
  - youtube_explode_dart (YouTube extraction)
  - dio (downloads)

## Architecture
- `models/` - Data models (DetectedMedia, DownloadTask)
- `services/` - Business logic (MediaSniffer, YouTube, Download, FFmpeg)
- `providers/` - State management (BrowserProvider, DownloadProvider)
- `screens/` - UI screens (BrowserScreen)
- `widgets/` - Reusable UI components

## Key Patterns
- Media detection via WebView's onLoadResource callback
- YouTube videos handled via youtube_explode_dart (not scraping)
- DASH videos require FFmpeg merge of video + audio streams (placeholder implementation)
- Downloads saved to `/storage/emulated/0/Download/MediaTube/`

## Running the App
```bash
flutter pub get
flutter run
```

## Building Release APK
```bash
flutter build apk --release
```
