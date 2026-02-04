import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/update_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Performance optimizations
  // Enable Impeller on Android for better rendering (if available)
  // Reduce jank by pre-warming image cache

  // ============================================================
  // FUTURE: Initialize Mobile Ads SDK here
  // Example for Google AdMob:
  // await MobileAds.instance.initialize();
  //
  // This should be done BEFORE the update check to ensure ads
  // infrastructure is ready, but it should NOT block the app launch.
  // Consider using a non-blocking initialization pattern:
  // MobileAds.instance.initialize(); // Without await
  // ============================================================

  // Request necessary permissions
  await _requestPermissions();

  // Initialize InAppWebView (for Android)
  if (await WebViewFeature.isFeatureSupported(
    WebViewFeature.WEB_MESSAGE_LISTENER,
  )) {
    // WebView is supported
  }

  runApp(const MediaTubeApp());
}

Future<void> _requestPermissions() async {
  // Request storage permissions
  await [
    Permission.storage,
    Permission.manageExternalStorage,
    Permission.notification,
  ].request();
}

class MediaTubeApp extends StatelessWidget {
  const MediaTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BrowserProvider()),
        ChangeNotifierProvider(create: (_) => DownloadProvider()),
      ],
      child: MaterialApp(
        title: 'MediaTube',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const MediaTubeHome(),
      ),
    );
  }
}

class MediaTubeHome extends StatefulWidget {
  const MediaTubeHome({super.key});

  @override
  State<MediaTubeHome> createState() => _MediaTubeHomeState();
}

class _MediaTubeHomeState extends State<MediaTubeHome> {
  bool _permissionsGranted = false;
  bool _updateCheckDone = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final storageStatus = await Permission.storage.status;
    final manageStatus = await Permission.manageExternalStorage.status;

    setState(() {
      _permissionsGranted = storageStatus.isGranted || manageStatus.isGranted;
    });

    // Check for updates after permissions are verified
    // This runs once when the app starts
    if (!_updateCheckDone) {
      _updateCheckDone = true;
      // Use addPostFrameCallback to ensure context is available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkForUpdates();
      });
    }
  }

  Future<void> _checkForUpdates() async {
    // Small delay to ensure the UI is fully rendered before showing dialog
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      await UpdateManager().checkForUpdates(context);
    }
  }

  Future<void> _requestPermissions() async {
    await [Permission.storage, Permission.manageExternalStorage].request();
    _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsGranted) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_off, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'Storage Permission Required',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'MediaTube needs storage permission to download and save media files.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _requestPermissions,
                  icon: const Icon(Icons.folder),
                  label: const Text('Grant Permission'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _permissionsGranted = true;
                    });
                  },
                  child: const Text('Continue Anyway'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const BrowserScreen();
  }
}
