// Developer - Rajesh Biswas
// Website - https://rajeshbiswas.dev
// GitHub - https://github.com/rajeshbsws557
// Version - 1.0.0
// License - MIT

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'models/models.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/services.dart';
import 'dart:ui';
import 'dart:isolate';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:audio_session/audio_session.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  final SendPort? sendPort = IsolateNameServer.lookupPortByName(
    'download_actions_port',
  );
  if (sendPort != null) {
    if (notificationResponse.actionId != null) {
      // payload will hold task ID or similar context, while actionId is the verb
      if (notificationResponse.payload != null) {
        sendPort.send(
          '${notificationResponse.actionId}_${notificationResponse.payload}',
        );
      } else {
        sendPort.send(notificationResponse.actionId);
      }
    } else if (notificationResponse.payload != null) {
      sendPort.send('open_${notificationResponse.payload}');
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarDividerColor: Colors.black,
    ),
  );

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('Audio session configuration failed: $e');
  }

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

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

double _maxInset(double a, double b) => a > b ? a : b;

EdgeInsets _normalizedSafePadding(MediaQueryData mediaQuery) {
  final keyboardVisible = mediaQuery.viewInsets.bottom > 0;

  return EdgeInsets.only(
    left: _maxInset(mediaQuery.padding.left, mediaQuery.viewPadding.left),
    top: _maxInset(mediaQuery.padding.top, mediaQuery.viewPadding.top),
    right: _maxInset(mediaQuery.padding.right, mediaQuery.viewPadding.right),
    bottom: keyboardVisible
        ? mediaQuery.padding.bottom
        : _maxInset(mediaQuery.padding.bottom, mediaQuery.viewPadding.bottom),
  );
}

class MediaTubeApp extends StatelessWidget {
  const MediaTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const youtubeRed = Color(0xFFFF0000);
    final lightScheme = ColorScheme.fromSeed(
      seedColor: youtubeRed,
      brightness: Brightness.light,
    ).copyWith(
      primary: youtubeRed,
      secondary: youtubeRed,
      onPrimary: Colors.white,
    );

    final darkScheme = ColorScheme.fromSeed(
      seedColor: youtubeRed,
      brightness: Brightness.dark,
    ).copyWith(
      primary: youtubeRed,
      secondary: youtubeRed,
      onPrimary: Colors.white,
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BrowserProvider()),
        ChangeNotifierProvider(create: (_) => DownloadProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        title: 'MediaTube',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: scaffoldMessengerKey,
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          final normalizedMediaQuery = mediaQuery.copyWith(
            padding: _normalizedSafePadding(mediaQuery),
          );

          return MediaQuery(
            data: normalizedMediaQuery,
            child: child ?? const SizedBox.shrink(),
          );
        },
        theme: ThemeData(
          colorScheme: lightScheme,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          navigationBarTheme: NavigationBarThemeData(
            indicatorColor: youtubeRed.withAlpha(36),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: darkScheme,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          navigationBarTheme: NavigationBarThemeData(
            indicatorColor: youtubeRed.withAlpha(50),
          ),
        ),
        themeMode: ThemeMode.system,
        home: const MediaTubeBootstrap(),
      ),
    );
  }
}

class MediaTubeBootstrap extends StatefulWidget {
  const MediaTubeBootstrap({super.key});

  @override
  State<MediaTubeBootstrap> createState() => _MediaTubeBootstrapState();
}

class _MediaTubeBootstrapState extends State<MediaTubeBootstrap> {
  static const Duration _splashDuration = Duration(milliseconds: 2400);
  Timer? _splashTimer;
  bool _showMainApp = false;

  @override
  void initState() {
    super.initState();
    _splashTimer = Timer(_splashDuration, () {
      if (!mounted) return;
      setState(() {
        _showMainApp = true;
      });
    });
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _showMainApp
          ? const MediaTubeHome(key: ValueKey('home'))
          : const MediaTubeSplashScreen(key: ValueKey('splash')),
    );
  }
}

class MediaTubeSplashScreen extends StatelessWidget {
  const MediaTubeSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final viewPadding = MediaQuery.viewPaddingOf(context);

    return Scaffold(
      body: SizedBox.expand(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF080808),
                Color(0xFF151515),
                Color(0xFF2A0000),
              ],
              stops: [0.0, 0.58, 1.0],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: -64,
                right: -38,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withAlpha(28),
                  ),
                ),
              ),
              Positioned(
                bottom: -74,
                left: -34,
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(16),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  viewPadding.top + 20,
                  24,
                  viewPadding.bottom + 20,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 640;
                    final tileSize = compact ? 104.0 : 124.0;
                    final tileRadius = compact ? 30.0 : 36.0;
                    final tilePadding = compact ? 14.0 : 16.0;
                    final titleGap = compact ? 14.0 : 20.0;

                    return Column(
                      children: [
                        const Spacer(flex: 2),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.9, end: 1),
                          duration: const Duration(milliseconds: 900),
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) => Transform.scale(
                            scale: scale,
                            child: child,
                          ),
                          child: Container(
                            width: tileSize,
                            height: tileSize,
                            padding: EdgeInsets.all(tilePadding),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(tileRadius),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x66FF0000),
                                  blurRadius: 24,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Image.asset(
                              'assets/icon.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        SizedBox(height: titleGap),
                        Text(
                          'MediaTube',
                          textAlign: TextAlign.center,
                          style: textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Fast media browsing and capture',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withAlpha(190),
                            letterSpacing: 0.2,
                          ),
                        ),
                        const Spacer(flex: 3),
                        Text(
                          'Developed By Rajesh Biswas',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withAlpha(180),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
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
  DateTime _lastOpenUpdateCheckAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isOpenUpdateCheckRunning = false;

  static const Duration _openUpdateCheckCooldown = Duration(seconds: 20);

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
      unawaited(_triggerOpenUpdateCheck());
    }
  }

  Future<void> _triggerOpenUpdateCheck({bool force = false}) async {
    if (!mounted || !_permissionsGranted) {
      return;
    }

    final now = DateTime.now();
    final shouldThrottle =
        !force &&
        now.difference(_lastOpenUpdateCheckAt) < _openUpdateCheckCooldown;

    if (_isOpenUpdateCheckRunning || shouldThrottle) {
      return;
    }

    _isOpenUpdateCheckRunning = true;
    _lastOpenUpdateCheckAt = now;

    try {
      await UpdateManager().checkForUpdates(context);
    } catch (e) {
      debugPrint('Open update check failed: $e');
    } finally {
      _isOpenUpdateCheckRunning = false;
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
    debugPrint('Shared content received');
    final url = ShareUrlService.normalizeSharedUrl(content);
    if (url == null || !ShareUrlService.isSupportedWebUrl(url)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unsupported shared link format. Please share a web post URL.'),
        ),
      );
      return;
    }

    if (!mounted) return;

    final settings = context.read<SettingsProvider>();
    final downloadProvider = context.read<DownloadProvider>();
    final action = settings.defaultShareAction;

    if (action != DefaultShareAction.alwaysAsk) {
      // Headless auto-download execution
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == DefaultShareAction.autoVideo
                ? 'Downloading Best Video...'
                : 'Downloading Audio...',
          ),
          duration: const Duration(seconds: 2),
        ),
      );

      final ytService = YouTubeService();
      if (ytService.isValidYouTubeUrl(url)) {
        try {
          final streams = await ytService.getAvailableStreams(url);
          if (streams.isNotEmpty && context.mounted) {
            DetectedMedia selectedOption;
            if (action == DefaultShareAction.autoVideo) {
              // Pick highest quality video format (first non-audio-only)
              selectedOption = streams.firstWhere(
                (s) => s.type != MediaType.audio,
                orElse: () => streams.first,
              );
            } else {
              // Pick audio only
              selectedOption = streams.firstWhere(
                (s) => s.type == MediaType.audio,
                orElse: () => streams.last, // fallback to lowest res
              );
            }
            downloadProvider.startDownload(selectedOption);
            _moveToBackgroundAfterDelay();
          }
        } catch (e) {
          debugPrint('Headless fetch failed: $e');
          // If headless fails, fallback to UI
          if (!mounted) return;
          context.read<BrowserProvider>().setPendingUrl(url);
        }
      } else {
        final started = await _tryAutoDownloadSharedSocial(
          url: url,
          action: action,
          downloadProvider: downloadProvider,
        );

        if (!mounted) return;

        if (started) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Auto download started from shared link'),
              duration: Duration(seconds: 2),
            ),
          );
          _moveToBackgroundAfterDelay();
        } else {
          // Fallback to browser sheet flow if quick auto mode cannot detect streams.
          context.read<BrowserProvider>().setPendingUrl(url);
        }
      }
    } else {
      // Always Ask - Set pending URL for BrowserScreen to handle
      context.read<BrowserProvider>().setPendingUrl(url);
    }
  }

  void _moveToBackgroundAfterDelay() {
    Future.delayed(const Duration(milliseconds: 1500), () async {
      try {
        const platform = MethodChannel('com.rajesh.mediatube/app');
        await platform.invokeMethod('moveToBackground');
      } catch (_) {
        SystemNavigator.pop();
      }
    });
  }

  Future<bool> _tryAutoDownloadSharedSocial({
    required String url,
    required DefaultShareAction action,
    required DownloadProvider downloadProvider,
  }) async {
    final extractor = WebViewExtractorService();
    final candidates = _buildShareExtractionCandidates(url);

    for (final candidate in candidates) {
      try {
        final media = await extractor
            .extractMedia(candidate)
            .timeout(const Duration(seconds: 12));
        if (media.isEmpty) {
          continue;
        }

        final selected = _pickBestAutoMedia(media, action);
        if (selected == null) {
          continue;
        }

        await downloadProvider.startDownload(selected);
        return true;
      } catch (e) {
        debugPrint('Auto social extraction failed for a candidate URL: $e');
      }
    }

    return false;
  }

  List<String> _buildShareExtractionCandidates(String rawUrl) {
    final normalized = ShareUrlService.normalizeSharedUrl(rawUrl) ?? rawUrl;
    final candidates = <String>[];

    void add(String value) {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return;
      }

      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        return;
      }

      final cleaned = uri.toString();
      if (!candidates.contains(cleaned)) {
        candidates.add(cleaned);
      }
    }

    add(normalized);

    final uri = Uri.tryParse(normalized);
    if (uri != null) {
      final host = uri.host.toLowerCase();
      if (host.contains('facebook.com') || host.contains('fb.watch')) {
        add(uri.replace(scheme: 'https', host: 'm.facebook.com').toString());
        add(uri.replace(scheme: 'https', host: 'www.facebook.com').toString());

        final watchId = uri.queryParameters['v'] ?? uri.queryParameters['video_id'];
        if (watchId != null && watchId.isNotEmpty) {
          add('https://m.facebook.com/watch/?v=$watchId');
        }
      }

      if (host.contains('instagram.com') || host == 'instagr.am') {
        add(uri.replace(scheme: 'https', host: 'www.instagram.com').toString());
        add(uri.replace(scheme: 'https', host: 'm.instagram.com').toString());

        final segments = uri.pathSegments;
        final reelIndex = segments.indexOf('reel');
        if (reelIndex != -1 && reelIndex + 1 < segments.length) {
          add('https://www.instagram.com/reel/${segments[reelIndex + 1]}/');
        }
      }

      if (host.contains('tiktok.com')) {
        add(uri.replace(scheme: 'https', host: 'www.tiktok.com').toString());
        add(uri.replace(scheme: 'https', host: 'm.tiktok.com').toString());
      }

      if (host.contains('x.com') || host.contains('twitter.com')) {
        add(uri.replace(scheme: 'https', host: 'x.com').toString());

        final statusMatch = RegExp(r'^/([^/]+)/status/(\d+)').firstMatch(uri.path);
        if (statusMatch != null) {
          add(
            'https://x.com/${statusMatch.group(1)}/status/${statusMatch.group(2)}',
          );
        }
      }
    }

    return candidates;
  }

  DetectedMedia? _pickBestAutoMedia(
    List<DetectedMedia> media,
    DefaultShareAction action,
  ) {
    List<DetectedMedia> candidates;

    if (action == DefaultShareAction.autoAudio) {
      candidates = media.where((m) => m.type == MediaType.audio).toList();
      if (candidates.isEmpty) {
        return null;
      }
    } else {
      candidates = media
          .where((m) => m.type == MediaType.video || m.type == MediaType.stream)
          .toList();
      if (candidates.isEmpty) {
        candidates = media;
      }
    }

    if (candidates.isEmpty) {
      return null;
    }

    int score(DetectedMedia item) {
      var value = item.fileSize ?? 0;

      final quality = (item.quality ?? '').toLowerCase();
      final qualityMatch = RegExp(r'(\d{3,4})p').firstMatch(quality);
      if (qualityMatch != null) {
        value += int.parse(qualityMatch.group(1)!) * 1024 * 1024;
      }

      if (item.type == MediaType.video) {
        value += 2 * 1024 * 1024;
      }

      final format = (item.format ?? '').toLowerCase();
      if (format == 'm3u8' || format == 'mpd') {
        value -= 5 * 1024 * 1024;
      }

      if (item.isDash) {
        value -= 512 * 1024;
      }

      return value;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first;
  }

  Future<void> _checkPermissions() async {
    final storageStatus = await Permission.storage.status;
    var fallbackStorageReady = false;

    try {
      final downloadService = DownloadService();
      await downloadService.ensureDownloadDirectory();
      downloadService.dispose();
      fallbackStorageReady = true;
    } catch (_) {
      fallbackStorageReady = false;
    }

    setState(() {
      _permissionsGranted = storageStatus.isGranted || fallbackStorageReady;
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
        unawaited(_triggerOpenUpdateCheck(force: true));
      }
    } catch (e) {
      debugPrint("Startup check error: $e");
    }
  }

  Future<void> _requestPermissions() async {
    await [Permission.storage, Permission.notification].request();
    _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsGranted) {
      return Scaffold(
        body: SafeArea(
          child: Center(
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
        ),
      );
    }

    return const BrowserScreen();
  }
}
