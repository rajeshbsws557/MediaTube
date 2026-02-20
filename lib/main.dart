// Developer - Rajesh Biswas
// Website - https://rajeshbiswas.dev
// GitHub - https://github.com/rajeshbsws557
// Version - 1.0.0
// License - MIT

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/update_manager.dart';
import 'services/security_service.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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

  // Initialize port for foreground task communication
  FlutterForegroundTask.initCommunicationPort();

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

class _MediaTubeHomeState extends State<MediaTubeHome>
    with WidgetsBindingObserver {
  bool _permissionsGranted = false;
  bool _updateCheckDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
    _configureIntentHandling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Guard to avoid duplicate saves on rapid lifecycle events
  bool _hasSavedOnPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Save on BOTH paused and detached for maximum reliability.
    // AppLifecycleState.detached is unreliable on Android and often never fires.
    // Saving on paused ensures history is persisted when user switches apps or
    // the OS kills the app. The foreground service keeps downloads running.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!_hasSavedOnPause) {
        _hasSavedOnPause = true;
        context.read<DownloadProvider>().saveActiveDownloadsToHistory();
      }
    } else if (state == AppLifecycleState.resumed) {
      _hasSavedOnPause = false;
    }
  }

  void _configureIntentHandling() {
    // Listen for intent while app is running
    ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> value) {
        if (value.isNotEmpty && value.first.path.isNotEmpty) {
          _handleSharedContent(value.first.path);
        }
      },
      onError: (err) {
        debugPrint("Intent Error: $err");
      },
    );

    // Check intent on app startup
    ReceiveSharingIntent.instance.getInitialMedia().then((
      List<SharedMediaFile> value,
    ) {
      if (value.isNotEmpty && value.first.path.isNotEmpty) {
        _handleSharedContent(value.first.path);
      }
    });
  }

  Future<void> _handleSharedContent(String content) async {
    debugPrint("Shared content received: $content");
    // YouTube share often comes as "Title https://youtu.be/..." or just URL
    // Extract generic URL logic
    final urlRegex = RegExp(r'https?://\S+');
    final match = urlRegex.firstMatch(content);
    final url =
        match?.group(0) ??
        content; // Use extracted URL or full content if no match

    // Set pending URL for BrowserScreen to handle
    if (context.mounted) {
      context.read<BrowserProvider>().setPendingUrl(url);
    }
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
      // Schedule checks to run AFTER the first frame is rendered to avoid startup freeze
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runStartupChecks();
      });
    }
  }

  Future<void> _runStartupChecks() async {
    // Give UI time to stabilize completely (non-blocking delay)
    await Future.delayed(const Duration(seconds: 3));

    try {
      // 1. Verify Security (Anti-Clone) - Fast local check
      if (!mounted) return;

      // Use microtask to ensure we don't block the main thread even for local check
      final secure = await Future.microtask(() async {
        if (!mounted) return true;
        return await SecurityService().verifyIntegrity(context);
      });

      if (!secure) return;

      // 2. Check for Updates - Network call (slow)
      if (mounted) {
        // Run completely in background, don't await result to avoid blocking
        UpdateManager().checkForUpdates(context).catchError((e) {
          debugPrint("Update check background error: $e");
        });
      }
    } catch (e) {
      debugPrint("Startup check error: $e");
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
