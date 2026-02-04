/// App Configuration
///
/// This file contains configurable values for the MediaTube app.
/// Copy this file to `app_config.local.dart` and modify for local development.
/// The .local.dart file is gitignored and won't be committed.

class AppConfig {
  /// Backend server URL (OPTIONAL - used as fallback only)
  ///
  /// Native on-device extraction is now the default!
  /// The server is only used if native extraction fails.
  ///
  /// For Android emulator: 'http://10.0.2.2:5000'
  /// For physical device on same network: 'http://YOUR_LOCAL_IP:5000'
  /// For production: 'https://your-server.com'
  static const String backendBaseUrl = 'http://192.168.1.147:5000';

  /// GitHub repository URL for releases
  /// Update this with your actual GitHub username
  static const String githubReleasesUrl =
      'https://github.com/YOUR_USERNAME/MediaTube/releases';

  /// Current app version (should match pubspec.yaml)
  static const String appVersion = '1.0.0';
}
