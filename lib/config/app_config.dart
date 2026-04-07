// App Configuration
//
// This file contains configurable values for the MediaTube app.
// Copy this file to `app_config.local.dart` and modify for local development.
// The .local.dart file is gitignored and won't be committed.

class AppConfig {
  /// Backend server URL (OPTIONAL - used as fallback only)
  ///
  /// Native on-device extraction is now the default!
  /// The server is only used if native extraction fails.
  ///
  /// For Android emulator: 'http://10.0.2.2:5000'
  /// For physical device on same network: 'http://YOUR_LOCAL_IP:5000'
  /// For production: 'https://your-server.com'
  /// Backend server URL (Legacy/Fallback)
  ///
  /// Keep this HTTPS by default. Override at build time for local debugging:
  /// flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:5000
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://your-server.com',
  );

  /// GitHub repository owner
  static const String githubRepoOwner = 'rajeshbsws557';

  /// GitHub repository name
  static const String githubRepoName = 'MediaTube';

  /// GitHub releases URL (derived)
  static const String githubReleasesUrl =
      'https://github.com/$githubRepoOwner/$githubRepoName/releases';

  /// Current app version (should match pubspec.yaml)
  static const String appVersion = '1.0.3';

  // ============================================================
  // SECURITY CONFIGURATION
  // ============================================================

  /// Expected package name for anti-clone check
  static const String expectedPackageName = 'com.rajesh.mediatube';

  /// Expected signing certificate SHA-256 hash
  /// Run the app once to see the actual hash in logs, then update this value.
  /// This ensures only the official APK signed by YOU can run.
  static const String expectedSignatureHash =
      '57d380b541b2f33ce86d29bb35de14f4f23c536e426e33dad8ad1478d55b55ff'; // Security locked
}
