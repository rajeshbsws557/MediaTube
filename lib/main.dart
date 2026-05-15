// Developer - Rajesh Biswas
// Website - https://rajeshbiswas.dev
// GitHub - https://github.com/rajeshbsws557
// Version - 1.0.0
// License - MIT

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models/models.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/services.dart';
import 'dart:ui';
import 'dart:isolate';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

  // Initialize port for foreground task communication
  FlutterForegroundTask.initCommunicationPort();

  runApp(const MediaTubeApp());
}

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

EdgeInsets _normalizedSafePadding(MediaQueryData mediaQuery) {
  final keyboardVisible = mediaQuery.viewInsets.bottom > 0;

  return EdgeInsets.only(
    left: math.max(mediaQuery.padding.left, mediaQuery.viewPadding.left),
    top: math.max(mediaQuery.padding.top, mediaQuery.viewPadding.top),
    right: math.max(mediaQuery.padding.right, mediaQuery.viewPadding.right),
    bottom: keyboardVisible
        ? mediaQuery.padding.bottom
        : math.max(mediaQuery.padding.bottom, mediaQuery.viewPadding.bottom),
  );
}

class MediaTubeApp extends StatelessWidget {
  const MediaTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const youtubeRed = Color(0xFFFF0000);
    final lightScheme =
        ColorScheme.fromSeed(
          seedColor: youtubeRed,
          brightness: Brightness.light,
        ).copyWith(
          primary: youtubeRed,
          secondary: const Color(0xFF1A1A1A),
          onPrimary: Colors.white,
          surface: const Color(0xFFF8F9FA),
        );

    final darkScheme =
        ColorScheme.fromSeed(
          seedColor: youtubeRed,
          brightness: Brightness.dark,
        ).copyWith(
          primary: youtubeRed,
          secondary: const Color(0xFFE0E0E0),
          onPrimary: Colors.white,
          surface: const Color(0xFF0E0E12),
          surfaceContainerHighest: const Color(0xFF1C1C24),
          onSurface: const Color(0xFFE8E8EC),
          outline: const Color(0xFF3A3A44),
          outlineVariant: const Color(0xFF2A2A34),
        );

    final baseTheme = ThemeData(useMaterial3: true);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BrowserProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProxyProvider<SettingsProvider, DownloadProvider>(
          create: (_) => DownloadProvider(),
          update: (_, settings, downloadProvider) {
            final provider = downloadProvider ?? DownloadProvider();
            provider.setMaxConcurrentDownloads(settings.maxConcurrentDownloads);
            return provider;
          },
        ),
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
        theme: baseTheme.copyWith(
          colorScheme: lightScheme,
          scaffoldBackgroundColor: lightScheme.surface,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            clipBehavior: Clip.antiAlias,
            color: Colors.white,
          ),
          bottomSheetTheme: const BottomSheetThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: true,
            backgroundColor: Colors.transparent,
            iconTheme: IconThemeData(color: Colors.black87),
          ),
          navigationBarTheme: NavigationBarThemeData(
            indicatorColor: youtubeRed.withAlpha(36),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            elevation: 0,
            backgroundColor: Colors.white.withValues(alpha: 0.95), // Modern slightly transparent nav
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 4,
          ),
        ),
        darkTheme: baseTheme.copyWith(
          colorScheme: darkScheme,
          scaffoldBackgroundColor: darkScheme.surface,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            clipBehavior: Clip.antiAlias,
            color: const Color(0xFF161620),
          ),
          bottomSheetTheme: const BottomSheetThemeData(
            elevation: 0,
            backgroundColor: Color(0xFF121218),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: true,
            backgroundColor: Colors.transparent,
            iconTheme: IconThemeData(color: Colors.white70),
          ),
          navigationBarTheme: NavigationBarThemeData(
            indicatorColor: youtubeRed.withAlpha(50),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            elevation: 0,
            backgroundColor: const Color(0xFF121212).withValues(alpha: 0.95),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 4,
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
  bool _showMainApp = false;

  void _onReady() {
    if (!mounted) return;
    setState(() {
      _showMainApp = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _showMainApp
          ? MediaTubeHome(key: const ValueKey('home'))
          : MediaTubeHome(
              key: const ValueKey('splash_wrapper'),
              isSplashWrapper: true,
              onReady: _onReady,
            ),
    );
  }
}


class MediaTubeSplashScreen extends StatefulWidget {
  const MediaTubeSplashScreen({super.key});

  @override
  State<MediaTubeSplashScreen> createState() => _MediaTubeSplashScreenState();
}

class _MediaTubeSplashScreenState extends State<MediaTubeSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

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
              colors: [Color(0xFF060608), Color(0xFF0E0E18), Color(0xFF2A0008)],
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
                    gradient: RadialGradient(
                      colors: [
                        Colors.red.withAlpha(32),
                        Colors.red.withAlpha(0),
                      ],
                    ),
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
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withAlpha(12),
                        Colors.white.withAlpha(0),
                      ],
                    ),
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
                          tween: Tween<double>(begin: 0.85, end: 1),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0.0, end: 1.0),
                            duration: const Duration(milliseconds: 500),
                            builder: (context, opacity, child) =>
                                Opacity(opacity: opacity, child: child),
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
                                    blurRadius: 32,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: Image.asset(
                                'assets/icon.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: titleGap),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 600),
                          curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
                          builder: (context, opacity, child) =>
                              Opacity(opacity: opacity, child: child),
                          child: Text(
                            'MediaTube',
                            textAlign: TextAlign.center,
                            style: textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        AnimatedBuilder(
                          animation: _shimmerController,
                          builder: (context, child) {
                            return ShaderMask(
                              shaderCallback: (bounds) {
                                return LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: const [
                                    Color(0x80FFFFFF),
                                    Color(0xFFFFFFFF),
                                    Color(0x80FFFFFF),
                                  ],
                                  stops: [
                                    (_shimmerController.value - 0.3).clamp(0.0, 1.0),
                                    _shimmerController.value,
                                    (_shimmerController.value + 0.3).clamp(0.0, 1.0),
                                  ],
                                ).createShader(bounds);
                              },
                              child: child!,
                            );
                          },
                          child: Text(
                            'Fast media browsing and capture',
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withAlpha(200),
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        const Spacer(flex: 3),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 800),
                          curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
                          builder: (context, opacity, child) =>
                              Opacity(opacity: opacity, child: child),
                          child: Text(
                            'Developed By Rajesh Biswas',
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withAlpha(160),
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.6,
                            ),
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
  final bool isSplashWrapper;
  final VoidCallback? onReady;

  const MediaTubeHome({super.key, this.isSplashWrapper = false, this.onReady});

  @override
  State<MediaTubeHome> createState() => _MediaTubeHomeState();
}

class _MediaTubeHomeState extends State<MediaTubeHome>
    with WidgetsBindingObserver {
  bool _storagePermissionGranted = false;
  bool _bypassedPermissionScreen = false;
  bool _updateCheckDone = false;
  DateTime _lastOpenUpdateCheckAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isOpenUpdateCheckRunning = false;
  final List<String> _pendingSharedUrls = <String>[];
  StreamSubscription<String>? _shareIntentSubscription;
  bool _isProcessingSharedUrl = false;

  static const Duration _openUpdateCheckCooldown = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
    _configureIntentHandling();
  }

  @override
  void dispose() {
    unawaited(_shareIntentSubscription?.cancel());
    _shareIntentSubscription = null;
    unawaited(ShareIntentService.instance.dispose());
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
      unawaited(_triggerOpenUpdateCheck(force: true));
    }
  }

  Future<void> _triggerOpenUpdateCheck({bool force = false}) async {
    if (!mounted) {
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
    unawaited(_shareIntentSubscription?.cancel());
    _shareIntentSubscription = ShareIntentService.instance.sharedUrlStream
        .listen(
          (String sharedUrl) {
            _enqueueSharedUrl(sharedUrl);
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Share intent listener error: $error');
            debugPrint('$stackTrace');
          },
        );

    unawaited(ShareIntentService.instance.initialize());
  }

  void _enqueueSharedUrl(String sharedUrl) {
    final trimmed = sharedUrl.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _pendingSharedUrls.add(trimmed);
    if (!_isProcessingSharedUrl) {
      unawaited(_drainPendingSharedUrls());
    }
  }

  Future<void> _drainPendingSharedUrls() async {
    if (_isProcessingSharedUrl) {
      return;
    }

    _isProcessingSharedUrl = true;
    try {
      while (mounted && _pendingSharedUrls.isNotEmpty) {
        final nextSharedUrl = _pendingSharedUrls.removeAt(0);
        unawaited(_handleSharedContent(nextSharedUrl));
      }
    } finally {
      _isProcessingSharedUrl = false;
    }
  }

  void _showShareStatus(
    String message, {
    bool isError = false,
    bool isTransient = false,
    SnackBarAction? action,
  }) {
    if (!mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: isTransient
            ? const Duration(seconds: 45)
            : const Duration(seconds: 4),
        backgroundColor: isError ? Colors.red.shade700 : null,
        action: action,
      ),
    );
  }

  String _inferMediaFormat(String directMediaUrl) {
    final uri = Uri.tryParse(directMediaUrl);
    final path = uri?.path.toLowerCase() ?? directMediaUrl.toLowerCase();

    if (path.endsWith('.m4a')) return 'm4a';
    if (path.endsWith('.mp3')) return 'mp3';
    if (path.endsWith('.webm')) return 'webm';
    if (path.endsWith('.mov')) return 'mov';
    if (path.endsWith('.mkv')) return 'mkv';
    if (path.endsWith('.aac')) return 'aac';
    if (path.endsWith('.ogg')) return 'ogg';

    return 'mp4';
  }

  String _buildSharedMediaTitle(SupportedSharePlatform platform) {
    final platformLabel = PlatformDetector.platformLabel(platform);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${platformLabel}_$timestamp';
  }

  Future<bool> _runShareFallbackFlow(
    String url,
    SupportedSharePlatform platform,
  ) async {
    if (!mounted) {
      return false;
    }

    final settings = context.read<SettingsProvider>();
    final downloadProvider = context.read<DownloadProvider>();
    final fallbackAction =
        settings.defaultShareAction == DefaultShareAction.autoAudio
        ? DefaultShareAction.autoAudio
        : DefaultShareAction.autoVideo;

    if (platform == SupportedSharePlatform.youtube) {
      try {
        final ytService = YouTubeService();
        final streams = await ytService
            .getAvailableStreams(url)
            .timeout(const Duration(seconds: 20));

        final selected = _pickBestAutoMedia(streams, fallbackAction);
        if (selected != null) {
          await downloadProvider.startDownload(selected);
          return true;
        }
      } catch (error) {
        debugPrint('YouTube fallback extraction failed: $error');
      }
    }

    try {
      final socialStarted = await _tryAutoDownloadSharedSocial(
        url: url,
        action: fallbackAction,
        downloadProvider: downloadProvider,
      );
      if (socialStarted) {
        return true;
      }
    } catch (error) {
      debugPrint('Social fallback extraction failed: $error');
    }

    if (mounted) {
      context.read<BrowserProvider>().setPendingUrl(url);
    }

    return false;
  }

  void _showShareError(String url) {
    if (!mounted) return;
    _showShareStatus(
      'Could not auto-extract.',
      isError: true,
      action: SnackBarAction(
        label: 'Retry',
        onPressed: () {
          _pendingSharedUrls.add(url);
          _drainPendingSharedUrls();
        },
      ),
    );
  }

  Future<void> _handleSharedContent(String content) async {
    final normalizedInput =
        ShareUrlService.normalizeSharedUrl(content) ?? content.trim();
    final url = normalizedInput.trim();
    if (url.isEmpty || !ShareUrlService.isSupportedWebUrl(url)) {
      _showShareStatus(
        'Could not extract media from this link.',
        isError: true,
      );
      return;
    }

    final platform = PlatformDetector.detect(url);
    final extractor = PlatformDetector.extractorForUrl(url);
    if (extractor == null || platform == SupportedSharePlatform.unsupported) {
      if (mounted) {
        context.read<BrowserProvider>().setPendingUrl(url);
      }
      _showShareStatus('Could not auto-extract. Open MediaTube to continue.');
      return;
    }

    _showShareStatus('Analyzing Link...', isTransient: true);

    try {
      final directMediaUrl = await extractor
          .extractDirectMediaUrl(url)
          .timeout(const Duration(seconds: 35));

      if (directMediaUrl == null ||
          !ShareUrlService.isSupportedWebUrl(directMediaUrl)) {
        final recovered = await _runShareFallbackFlow(url, platform);
        if (recovered) {
          if (mounted) {
            _showShareStatus('Download Started');
          }
          _moveToBackgroundAfterDelay();
          return;
        }

        _showShareError(url);
        return;
      }

      if (!mounted) {
        return;
      }

      final downloadProvider = context.read<DownloadProvider>();
      final media = DetectedMedia(
        url: directMediaUrl,
        title: _buildSharedMediaTitle(platform),
        type: MediaType.video,
        source: platform == SupportedSharePlatform.youtube
            ? MediaSource.youtube
            : MediaSource.generic,
        quality: 'Best',
        format: _inferMediaFormat(directMediaUrl),
        isDash: false,
        useBackend: false,
      );

      await downloadProvider.startDownload(media);
      if (!mounted) {
        return;
      }

      _showShareStatus('Download Started');
      _moveToBackgroundAfterDelay();
    } on TimeoutException catch (error, stackTrace) {
      debugPrint('Share extraction timeout: $error');
      debugPrint('$stackTrace');

      final recovered = await _runShareFallbackFlow(url, platform);
      if (recovered) {
        if (mounted) {
          _showShareStatus('Download Started');
        }
        _moveToBackgroundAfterDelay();
        return;
      }

      _showShareError(url);
    } catch (error, stackTrace) {
      debugPrint('Share extraction failed: $error');
      debugPrint('$stackTrace');

      final recovered = await _runShareFallbackFlow(url, platform);
      if (recovered) {
        if (mounted) {
          _showShareStatus('Download Started');
        }
        _moveToBackgroundAfterDelay();
        return;
      }

      _showShareError(url);
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

        final watchId =
            uri.queryParameters['v'] ?? uri.queryParameters['video_id'];
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

        final statusMatch = RegExp(
          r'^/([^/]+)/status/(\d+)',
        ).firstMatch(uri.path);
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
      _storagePermissionGranted = storageStatus.isGranted || fallbackStorageReady;
      if (_storagePermissionGranted) _bypassedPermissionScreen = true;
    });

    // Notify wrapper that permissions are checked and app is ready
    if (widget.isSplashWrapper) {
      widget.onReady?.call();
    }

    // Check for updates after permissions are verified
    // This runs once when the app starts
    if (!_updateCheckDone && !widget.isSplashWrapper) {
      _updateCheckDone = true;
      // Schedule checks to run AFTER the first frame is rendered to avoid startup freeze
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runStartupChecks();
      });
    }
  }

  Future<void> _runStartupChecks() async {
    // Wait for the rendered frame pipeline to settle instead of using a fixed delay.
    await WidgetsBinding.instance.endOfFrame;

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
    if (widget.isSplashWrapper) {
      return const MediaTubeSplashScreen();
    }

    if (!_storagePermissionGranted && !_bypassedPermissionScreen) {
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
                        _bypassedPermissionScreen = true;
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
