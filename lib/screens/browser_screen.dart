import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/providers.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../utils/utils.dart';
import '../widgets/widgets.dart';
import 'downloads_screen.dart';
import 'settings_screen.dart';
import 'youtube_playback_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ignore: unused_field
  static const String _youtubeHomeUrl = 'https://m.youtube.com';
  static const String _youtubeVisibilityBypassScript = r'''
    (() => {
      const stopVisibilityEvent = (event) => {
        event.stopImmediatePropagation();
      };

      try {
        Object.defineProperty(document, 'visibilityState', {
          get: () => 'visible',
          configurable: true,
        });
      } catch (_) {}

      try {
        Object.defineProperty(document, 'hidden', {
          get: () => false,
          configurable: true,
        });
      } catch (_) {}

      document.addEventListener('visibilitychange', stopVisibilityEvent, true);
      document.addEventListener('webkitvisibilitychange', stopVisibilityEvent, true);
    })();
  ''';
  static const double _omniFabSize = 58;
  static const double _streamFabSize = 42;
  static const double _omniActionWidth = 146;
  static const double _omniActionHeight = 42;

  static const String _omniFabXPrefKey = 'overlay.omni_fab.x';
  static const String _omniFabYPrefKey = 'overlay.omni_fab.y';
  static const String _streamFabXPrefKey = 'overlay.stream_fab.x';
  static const String _streamFabYPrefKey = 'overlay.stream_fab.y';

  InAppWebViewController? _webViewController;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();

  // Start with YouTube
  String _currentUrl = 'https://m.youtube.com';
  bool _showHomePage = true;

  // Flag to track if current session is from Share-to-Download
  bool _isShareToDownload = false;

  // Reactive listener for share-to-download intents
  BrowserProvider? _browserProviderRef;
  bool _isProcessingPendingUrl = false;
  bool _requestInterceptionEnabled = false;
  bool _isOmniMenuExpanded = false;
  bool _isStreamPulseActive = false;
  bool _keepAlivePlaybackScriptInjected = false;
  bool _playbackIntentHooksInjected = false;

  Offset _omniFabNormalized = const Offset(0.84, 0.78);
  Offset _streamFabNormalized = const Offset(0.88, 0.60);

  Timer? _backgroundPlaybackTimer;
  Timer? _foregroundPlaybackIntentPollTimer;
  Timer? _fabPersistDebounce;
  bool _backgroundPlaybackAutomationInProgress = false;
  int _backgroundPlaybackAutomationEpoch = 0;
  bool _backgroundPlaybackTickInProgress = false;
  bool _foregroundPlaybackIntentPollInProgress = false;
  bool _isCapturingPlaybackIntentForBackground = false;
  DateTime _lastBackgroundLifecycleCaptureAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  int _consecutiveNoPlaybackDetections = 0;
  String _lastPlaybackForegroundTitle = '';
  String _lastKnownPlaybackTitle = 'MediaTube';
  bool _lastForegroundPlaybackIntentPlay = false;
  bool _wasVideoPlayingBeforeBackground = false;
  bool _nativeBackgroundHandoffInProgress = false;
  String? _lastNativeBackgroundHandoffVideoId;
  DateTime _lastNativeBackgroundHandoffAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );
  int? _androidSdkInt;
  bool _androidSdkLookupInProgress = false;

  static const Duration _backgroundPlaybackTickInterval = Duration(seconds: 6);
  static const Duration _foregroundIntentPollInterval = Duration(
    milliseconds: 1200,
  );
  static const Duration _backgroundLifecycleDebounce = Duration(
    milliseconds: 180,
  );
  static const Duration _nativeBackgroundHandoffCooldown = Duration(
    seconds: 25,
  );
  static const int _maxNoPlaybackDetectionsBeforeStop = 3;

  SharedPreferences? _cachedPrefs;

  final BackgroundDownloadService _backgroundService =
      BackgroundDownloadService();
  final AndroidPlaybackBridgeService _nativePlaybackBridge =
      AndroidPlaybackBridgeService();
  final YouTubeService _backgroundYouTubeService = YouTubeService();
  bool _playbackForegroundProtectionEnabled = false;
  bool _browserPipConfigured = false;

  int _profileFrameSampleCount = 0;
  int _profileJankyFrameCount = 0;
  DateTime _lastFrameProfileLogAt = DateTime.fromMillisecondsSinceEpoch(0);

  late final AnimationController _omniMenuController;
  late final AnimationController _streamPulseController;

  bool _shouldEnableRequestInterception(BrowserProvider provider) {
    return provider.shouldObserveNetworkMedia;
  }

  Future<void> _syncRequestInterceptionMode(
    BrowserProvider provider, {
    bool force = false,
  }) async {
    final shouldEnable = _shouldEnableRequestInterception(provider);
    if (!force && _requestInterceptionEnabled == shouldEnable) {
      return;
    }

    _requestInterceptionEnabled = shouldEnable;
    final controller = _webViewController;
    if (controller == null) {
      return;
    }

    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          useShouldInterceptRequest: shouldEnable,
          allowBackgroundAudioPlaying: true,
        ),
      );
    } catch (e) {
      debugPrint('Failed to toggle request interception: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachFrameTimingProbe();
    unawaited(_nativePlaybackBridge.ensureListening());
    unawaited(_ensureAndroidSdkInt());
    _omniMenuController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _streamPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    unawaited(_loadFloatingButtonPositions());

    _urlController.text = _currentUrl;

    // Set up reactive listener for share-to-download intents
    // and preload WebView after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _browserProviderRef = Provider.of<BrowserProvider>(
        context,
        listen: false,
      );
      _browserProviderRef!.addListener(_checkAndProcessPendingUrl);
      // Check immediately in case a URL was set before listener attached
      _checkAndProcessPendingUrl();
      _startForegroundPlaybackIntentPolling();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detachFrameTimingProbe();
    _browserProviderRef?.removeListener(_checkAndProcessPendingUrl);
    _stopForegroundPlaybackIntentPolling();
    _stopBackgroundPlaybackAutomationLoop();
    unawaited(_configureBrowserPip(enabled: false));
    unawaited(_stopPlaybackForegroundProtection());
    _fabPersistDebounce?.cancel();
    _chromeAutoHideTimer?.cancel();
    _omniMenuController.dispose();
    _streamPulseController.dispose();
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  void _attachFrameTimingProbe() {
    if (!kDebugMode) {
      return;
    }
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  void _detachFrameTimingProbe() {
    if (!kDebugMode) {
      return;
    }
    SchedulerBinding.instance.removeTimingsCallback(_handleFrameTimings);
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    if (!kDebugMode || timings.isEmpty) {
      return;
    }

    var worstTotalMs = 0.0;
    var worstBuildMs = 0.0;
    var worstRasterMs = 0.0;

    for (final timing in timings) {
      final totalMs = timing.totalSpan.inMicroseconds / 1000;
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;

      worstTotalMs = math.max(worstTotalMs, totalMs);
      worstBuildMs = math.max(worstBuildMs, buildMs);
      worstRasterMs = math.max(worstRasterMs, rasterMs);

      _profileFrameSampleCount++;
      if (totalMs > 16.6) {
        _profileJankyFrameCount++;
      }
    }

    final now = DateTime.now();
    if (now.difference(_lastFrameProfileLogAt) < const Duration(seconds: 6) ||
        _profileFrameSampleCount < 20) {
      return;
    }

    final jankPercent =
        (_profileJankyFrameCount * 100) / _profileFrameSampleCount;

    if (jankPercent >= 12) {
      AppLogger.warning(
        'UI jank sample ${jankPercent.toStringAsFixed(1)}% '
        '($_profileJankyFrameCount/$_profileFrameSampleCount), '
        'worst frame ${worstTotalMs.toStringAsFixed(1)}ms '
        '[build ${worstBuildMs.toStringAsFixed(1)}ms, '
        'raster ${worstRasterMs.toStringAsFixed(1)}ms]',
      );
    }

    _profileFrameSampleCount = 0;
    _profileJankyFrameCount = 0;
    _lastFrameProfileLogAt = now;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _stopForegroundPlaybackIntentPolling();
      final now = DateTime.now();
      if (now.difference(_lastBackgroundLifecycleCaptureAt) >=
          _backgroundLifecycleDebounce) {
        _lastBackgroundLifecycleCaptureAt = now;
        unawaited(_capturePlaybackIntentAndActivateBackground());
      }
      return;
    }

    if (state == AppLifecycleState.resumed) {
      final hadBackgroundLoop =
          _backgroundPlaybackTimer != null ||
          _backgroundPlaybackAutomationInProgress;
      _stopBackgroundPlaybackAutomationLoop();
      _isCapturingPlaybackIntentForBackground = false;
      _startForegroundPlaybackIntentPolling();
      unawaited(_configureBrowserPip(enabled: false));
      unawaited(_stopPlaybackForegroundProtection());
      if (hadBackgroundLoop && _wasVideoPlayingBeforeBackground) {
        unawaited(_forceCurrentVideoPlayback(delayMs: 220));
      }
      _wasVideoPlayingBeforeBackground = false;
      // Clear transient markers so each background transition follows fresh user intent.
      unawaited(_clearBackgroundPlaybackMarkers());
      _checkClipboardForMedia();
      return;
    }

    if (state == AppLifecycleState.detached) {
      _stopForegroundPlaybackIntentPolling();
      _stopBackgroundPlaybackAutomationLoop();
      unawaited(_configureBrowserPip(enabled: false));
      unawaited(_stopPlaybackForegroundProtection());
    }
  }

  Future<void> _ensureAndroidSdkInt() async {
    if (!Platform.isAndroid ||
        _androidSdkInt != null ||
        _androidSdkLookupInProgress) {
      return;
    }

    _androidSdkLookupInProgress = true;
    try {
      const platform = MethodChannel('com.rajesh.mediatube/app');
      _androidSdkInt = await platform.invokeMethod<int>('getAndroidSdkInt');
    } catch (e) {
      debugPrint('Failed to read Android SDK level: $e');
      _androidSdkInt = null;
    } finally {
      _androidSdkLookupInProgress = false;
    }
  }

  void _startForegroundPlaybackIntentPolling() {
    if (_foregroundPlaybackIntentPollTimer != null) {
      return;
    }

    _foregroundPlaybackIntentPollTimer = Timer.periodic(
      _foregroundIntentPollInterval,
      (_) {
        if (!mounted || _isCapturingPlaybackIntentForBackground) {
          return;
        }

        unawaited(_refreshForegroundPlaybackIntentFromWebView());
      },
    );

    unawaited(_refreshForegroundPlaybackIntentFromWebView());
  }

  void _stopForegroundPlaybackIntentPolling() {
    _foregroundPlaybackIntentPollTimer?.cancel();
    _foregroundPlaybackIntentPollTimer = null;
    _foregroundPlaybackIntentPollInProgress = false;
  }

  Future<void> _refreshForegroundPlaybackIntentFromWebView() async {
    if (_foregroundPlaybackIntentPollInProgress) {
      return;
    }

    final controller = _webViewController;
    if (controller == null) {
      return;
    }

    _foregroundPlaybackIntentPollInProgress = true;
    try {
      await _injectPlaybackIntentHooksIfNeeded();
      final result = await controller.evaluateJavascript(
        source: '''
          (() => {
            const videos = Array.from(document.querySelectorAll('video'));
            let shouldContinue = false;

            videos.forEach((video) => {
              if (video.ended) {
                video.dataset.mtUserIntent = 'pause';
                delete video.dataset.mtBackgroundPlay;
                return;
              }

              const isActivelyPlaying = !video.paused && video.readyState > 2;
              if (isActivelyPlaying) {
                video.dataset.mtUserIntent = 'play';
                video.dataset.mtBackgroundPlay = 'true';
                shouldContinue = true;
                return;
              }

              if (video.dataset.mtUserIntent === 'play') {
                video.dataset.mtBackgroundPlay = 'true';
                shouldContinue = true;
              }
            });

            return shouldContinue;
          })();
        ''',
      );

      _lastForegroundPlaybackIntentPlay =
          result == true || result?.toString() == 'true';
    } catch (_) {
      // Keep previous value when WebView is between lifecycle states.
    } finally {
      _foregroundPlaybackIntentPollInProgress = false;
    }
  }

  Future<void> _configureBrowserPip({required bool enabled}) async {
    if (_browserPipConfigured == enabled) {
      return;
    }

    try {
      await _nativePlaybackBridge.configurePip(
        enabled: false,
        aspectWidth: 16,
        aspectHeight: 9,
        autoEnter: false,
      );
      _browserPipConfigured = enabled;
    } catch (e) {
      debugPrint('Browser PiP configuration failed: $e');
    }
  }

  Future<bool> _requestBrowserPipHandoff() async {
    if (_showHomePage) {
      return false;
    }

    await _configureBrowserPip(enabled: false);
    return false;
  }

  bool _shouldUseNativeYouTubeBackgroundFallback() {
    if (!Platform.isAndroid) {
      return false;
    }

    // Android 11 and below are notably less reliable for WebView playback
    // through Home + screen-off transitions.
    final sdk = _androidSdkInt;
    if (sdk != null) {
      return sdk <= 30;
    }

    // If SDK lookup isn't available yet, prefer safe fallback.
    return true;
  }

  bool _isLikelyYouTubePlaybackContext() {
    final provider = _browserProviderRef;
    final currentUrl = provider?.currentUrl ?? _currentUrl;
    return (provider?.isYouTubePage ?? false) ||
        _backgroundYouTubeService.isValidYouTubeUrl(currentUrl);
  }

  bool _isDirectBackgroundPlayableVideo(DetectedMedia media) {
    if (media.type != MediaType.video) {
      return false;
    }

    if (media.isDash || media.useBackend) {
      return false;
    }

    final uri = Uri.tryParse(media.url);
    if (uri == null || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return false;
    }

    final host = uri.host.toLowerCase();
    if (host.contains('youtube.com') || host == 'youtu.be') {
      return false;
    }

    return true;
  }

  int _extractResolutionScore(String quality) {
    final match = RegExp(
      r'(\d{3,4})p',
      caseSensitive: false,
    ).firstMatch(quality);
    return match == null ? 0 : int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _extractBitrateScore(String quality) {
    final match = RegExp(
      r'(\d{2,4})\s*kbps',
      caseSensitive: false,
    ).firstMatch(quality);
    return match == null ? 0 : int.tryParse(match.group(1) ?? '') ?? 0;
  }

  DetectedMedia? _pickBackgroundPlayableVideo(Iterable<DetectedMedia> media) {
    final directVideos = media.where(_isDirectBackgroundPlayableVideo).toList();

    if (directVideos.isEmpty) {
      return null;
    }

    directVideos.sort((a, b) {
      final scoreA = _extractResolutionScore(a.quality ?? '');
      final scoreB = _extractResolutionScore(b.quality ?? '');
      if (scoreA != scoreB) {
        return scoreB.compareTo(scoreA);
      }

      final sizeA = a.fileSize ?? 0;
      final sizeB = b.fileSize ?? 0;
      return sizeB.compareTo(sizeA);
    });

    return directVideos.first;
  }

  DetectedMedia? _pickBackgroundPlayableAudio(Iterable<DetectedMedia> media) {
    final audio = media.where((m) => m.type == MediaType.audio).toList();
    if (audio.isEmpty) {
      return null;
    }

    audio.sort((a, b) {
      final scoreA = _extractBitrateScore(a.quality ?? '');
      final scoreB = _extractBitrateScore(b.quality ?? '');
      if (scoreA != scoreB) {
        return scoreB.compareTo(scoreA);
      }

      final sizeA = a.fileSize ?? 0;
      final sizeB = b.fileSize ?? 0;
      return sizeB.compareTo(sizeA);
    });

    return audio.first;
  }

  Future<DetectedMedia?> _resolveNativeYouTubeBackgroundMedia() async {
    final provider = _browserProviderRef;
    final currentUrl = provider?.currentUrl ?? _currentUrl;

    if (!_backgroundYouTubeService.isValidYouTubeUrl(currentUrl)) {
      return null;
    }

    final currentVideoId = _backgroundYouTubeService.extractVideoId(currentUrl);
    final now = DateTime.now();
    if (currentVideoId != null &&
        _lastNativeBackgroundHandoffVideoId == currentVideoId &&
        now.difference(_lastNativeBackgroundHandoffAt) <
            _nativeBackgroundHandoffCooldown) {
      return null;
    }

    final available = provider?.detectedMedia ?? const <DetectedMedia>[];
    final fromYouTube = available
        .where((m) => m.source == MediaSource.youtube)
        .toList();

    final directVideo = _pickBackgroundPlayableVideo(fromYouTube);
    if (directVideo != null) {
      return directVideo;
    }

    final audioFromProvider = _pickBackgroundPlayableAudio(fromYouTube);
    if (audioFromProvider != null) {
      return audioFromProvider;
    }

    final bestMuxed = await _backgroundYouTubeService.getBestMuxedStream(
      currentUrl,
    );
    if (bestMuxed != null && _isDirectBackgroundPlayableVideo(bestMuxed)) {
      return bestMuxed.copyWith(
        source: MediaSource.youtube,
        videoId: currentVideoId,
      );
    }

    final streams = await _backgroundYouTubeService.getAvailableStreams(
      currentUrl,
      useBackendForDash: false,
    );

    final resolvedVideo = _pickBackgroundPlayableVideo(streams);
    if (resolvedVideo != null) {
      return resolvedVideo;
    }

    return _pickBackgroundPlayableAudio(streams);
  }

  Future<void> _attemptNativeYouTubeBackgroundHandoff() async {
    if (!mounted ||
        _showHomePage ||
        _nativeBackgroundHandoffInProgress ||
        !_isLikelyYouTubePlaybackContext()) {
      return;
    }

    _nativeBackgroundHandoffInProgress = true;
    try {
      final media = await _resolveNativeYouTubeBackgroundMedia();
      if (!mounted || media == null) {
        return;
      }

      final handoffVideoId =
          media.videoId ??
          _backgroundYouTubeService.extractVideoId(
            _browserProviderRef?.currentUrl ?? _currentUrl,
          );

      if (handoffVideoId != null) {
        _lastNativeBackgroundHandoffVideoId = handoffVideoId;
        _lastNativeBackgroundHandoffAt = DateTime.now();
      }

      final navigator = Navigator.of(context, rootNavigator: true);
      unawaited(
        YoutubePlaybackScreen.pushBackground(
          navigator: navigator,
          media: media,
        ),
      );
    } catch (e) {
      debugPrint('Native YouTube background handoff failed: $e');
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _nativeBackgroundHandoffInProgress = false;
      });
    }
  }

  /// Captures WebView playback intent and only enables background automation
  /// when user intent indicates playback should continue.
  Future<void> _capturePlaybackIntentAndActivateBackground() async {
    if (_isCapturingPlaybackIntentForBackground) {
      return;
    }

    _isCapturingPlaybackIntentForBackground = true;

    final controller = _webViewController;
    if (controller == null) {
      _wasVideoPlayingBeforeBackground = _lastForegroundPlaybackIntentPlay;
      _isCapturingPlaybackIntentForBackground = false;
      return;
    }

    var shouldContinue = _lastForegroundPlaybackIntentPlay;

    try {
      await _injectPlaybackIntentHooksIfNeeded();
      final result = await controller
          .evaluateJavascript(
            source: '''
          (() => {
            const videos = Array.from(document.querySelectorAll('video'));
            let shouldContinue = false;
            const pageHidden = document.hidden || document.visibilityState === 'hidden';

            videos.forEach((video) => {
              if (video.ended) {
                video.dataset.mtUserIntent = 'pause';
                delete video.dataset.mtBackgroundPlay;
                return;
              }

              const isActivelyPlaying = !video.paused && video.readyState > 2;
              if (isActivelyPlaying) {
                video.dataset.mtUserIntent = 'play';
                video.dataset.mtBackgroundPlay = 'true';
                shouldContinue = true;
                return;
              }

              if (video.dataset.mtUserIntent === 'play') {
                video.dataset.mtBackgroundPlay = 'true';
                shouldContinue = true;
                return;
              }

              if (video.dataset.mtUserIntent === 'pause') {
                return;
              }

              const jsPauseTime = parseInt(video.dataset.mtJsPauseTime || '0', 10);
              const timeSinceJsPause = Date.now() - jsPauseTime;
              const isJsInitiated = timeSinceJsPause < 1000;

              const hasProgress = (video.currentTime || 0) > 0;
              if ((pageHidden || !isJsInitiated) && hasProgress) {
                // Background pauses mostly happen without JS explicitly calling video.pause().
                // It's a native pause. Preserve playing intent.
                video.dataset.mtUserIntent = 'play';
                video.dataset.mtBackgroundPlay = 'true';
                shouldContinue = true;
              }
            });

            return shouldContinue;
          })();
        ''',
          )
          .timeout(
            const Duration(milliseconds: 550),
            onTimeout: () => _lastForegroundPlaybackIntentPlay,
          );

      shouldContinue = result == true || result?.toString() == 'true';
    } catch (e) {
      // Fall back to cached foreground intent for fast background transitions.
      shouldContinue =
          _lastForegroundPlaybackIntentPlay ||
          _playbackForegroundProtectionEnabled;
      debugPrint('Failed to capture playback intent: $e');
    }

    _wasVideoPlayingBeforeBackground = shouldContinue;

    if (_wasVideoPlayingBeforeBackground) {
      final pipHandoffReady = await _requestBrowserPipHandoff();

      if (_shouldUseNativeYouTubeBackgroundFallback() &&
          _isLikelyYouTubePlaybackContext()) {
        unawaited(_attemptNativeYouTubeBackgroundHandoff());
      } else if (!pipHandoffReady && _isLikelyYouTubePlaybackContext()) {
        unawaited(_attemptNativeYouTubeBackgroundHandoff());
      }

      unawaited(_activateBackgroundPlaybackAutomation(usePlaybackDelay: true));
    } else {
      // Video was paused by user — don't start background playback,
      // but do stop any existing foreground protection.
      unawaited(_configureBrowserPip(enabled: false));
      _stopBackgroundPlaybackAutomationLoop();
      unawaited(_stopPlaybackForegroundProtection());
    }

    _isCapturingPlaybackIntentForBackground = false;
  }

  /// Clears transient background markers from videos so the next lifecycle
  /// transition depends on fresh user intent.
  Future<void> _clearBackgroundPlaybackMarkers() async {
    final controller = _webViewController;
    if (controller == null) return;

    try {
      await controller.evaluateJavascript(
        source: '''
          (() => {
            document.querySelectorAll('video').forEach((v) => {
              delete v.dataset.mtBackgroundPlay;
              delete v.dataset.mtUserIntent;
            });
          })();
        ''',
      );
    } catch (_) {}
  }

  Future<void> _activateBackgroundPlaybackAutomation({
    bool usePlaybackDelay = false,
  }) async {
    if (_backgroundPlaybackAutomationInProgress) {
      return;
    }

    _backgroundPlaybackAutomationInProgress = true;
    final epoch = ++_backgroundPlaybackAutomationEpoch;
    _consecutiveNoPlaybackDetections = 0;

    try {
      final bootstrapTitle = _derivePlaybackForegroundTitle();
      _lastKnownPlaybackTitle = bootstrapTitle;
      await _ensurePlaybackForegroundProtection(title: bootstrapTitle);

      await _injectPlaybackIntentHooksIfNeeded();
      await _injectPlaybackKeepAliveScript();
      if (!mounted || epoch != _backgroundPlaybackAutomationEpoch) {
        return;
      }

      await _forceCurrentVideoPlayback(delayMs: usePlaybackDelay ? 300 : 0);
      if (!mounted || epoch != _backgroundPlaybackAutomationEpoch) {
        return;
      }

      await _syncPlaybackForegroundProtection();
      if (!mounted || epoch != _backgroundPlaybackAutomationEpoch) {
        return;
      }

      _backgroundPlaybackTimer?.cancel();
      _backgroundPlaybackTimer = Timer.periodic(
        _backgroundPlaybackTickInterval,
        (timer) {
          if (!mounted || epoch != _backgroundPlaybackAutomationEpoch) {
            timer.cancel();
            return;
          }

          if (_backgroundPlaybackTickInProgress) {
            return;
          }

          unawaited(() async {
            _backgroundPlaybackTickInProgress = true;
            try {
              await _forceCurrentVideoPlayback(delayMs: 250);
              await _syncPlaybackForegroundProtection();
            } finally {
              _backgroundPlaybackTickInProgress = false;
            }
          }());
        },
      );
    } finally {
      _backgroundPlaybackAutomationInProgress = false;
    }
  }

  void _stopBackgroundPlaybackAutomationLoop() {
    _backgroundPlaybackAutomationEpoch++;
    _backgroundPlaybackTimer?.cancel();
    _backgroundPlaybackTimer = null;
    _backgroundPlaybackAutomationInProgress = false;
    _backgroundPlaybackTickInProgress = false;
    _isCapturingPlaybackIntentForBackground = false;
    _consecutiveNoPlaybackDetections = 0;
  }

  String _derivePlaybackForegroundTitle() {
    final providerTitle = _browserProviderRef?.pageTitle.trim() ?? '';
    if (providerTitle.isNotEmpty) {
      return providerTitle;
    }

    final fallback = _urlController.text.trim();
    if (fallback.isNotEmpty) {
      return fallback;
    }

    return 'MediaTube';
  }

  Future<void> _ensurePlaybackForegroundProtection({
    required String title,
  }) async {
    final normalizedTitle = title.trim().isEmpty ? 'MediaTube' : title.trim();
    if (_playbackForegroundProtectionEnabled &&
        _lastPlaybackForegroundTitle == normalizedTitle) {
      return;
    }

    await _backgroundService.startPlaybackService(
      title: normalizedTitle,
      isVideo: true,
    );
    _playbackForegroundProtectionEnabled = true;
    _lastPlaybackForegroundTitle = normalizedTitle;
  }

  Future<bool> _syncPlaybackForegroundProtection() async {
    final controller = _webViewController;
    if (controller == null) {
      _consecutiveNoPlaybackDetections++;
      if (_consecutiveNoPlaybackDetections >=
          _maxNoPlaybackDetectionsBeforeStop) {
        await _stopPlaybackForegroundProtection();
      }
      return false;
    }

    try {
      final result = await controller.evaluateJavascript(
        source: '''
          (() => {
            const videos = Array.from(document.querySelectorAll('video'));
            const hasVideo = videos.length > 0;
            const isPlaying = videos.some((video) => !video.paused && !video.ended);
            const title = (document.title || 'MediaTube').trim();
            return [title, hasVideo, isPlaying];
          })();
        ''',
      );

      var title = 'MediaTube';
      var shouldProtect = false;

      if (result is List && result.length >= 3) {
        final rawTitle = result[0]?.toString().trim() ?? '';
        final hasVideo = result[1] == true || result[1]?.toString() == 'true';
        final isPlaying = result[2] == true || result[2]?.toString() == 'true';

        title = rawTitle.isEmpty ? title : rawTitle;
        shouldProtect = hasVideo && isPlaying;
      }

      if (shouldProtect) {
        _consecutiveNoPlaybackDetections = 0;
        _lastKnownPlaybackTitle = title;
        await _ensurePlaybackForegroundProtection(title: title);
        return true;
      }

      _consecutiveNoPlaybackDetections++;
      if (_consecutiveNoPlaybackDetections >=
          _maxNoPlaybackDetectionsBeforeStop) {
        await _stopPlaybackForegroundProtection();
      }
      return false;
    } catch (e) {
      debugPrint('Playback foreground protection sync failed: $e');
      if (!_playbackForegroundProtectionEnabled) {
        try {
          await _ensurePlaybackForegroundProtection(
            title: _lastKnownPlaybackTitle,
          );
        } catch (_) {}
      }
      return _playbackForegroundProtectionEnabled;
    }
  }

  Future<void> _stopPlaybackForegroundProtection() async {
    if (!_playbackForegroundProtectionEnabled) {
      return;
    }

    try {
      await _backgroundService.stopPlaybackService();
    } catch (e) {
      debugPrint('Failed to stop playback foreground protection: $e');
    } finally {
      _playbackForegroundProtectionEnabled = false;
      _lastPlaybackForegroundTitle = '';
    }
  }

  Future<void> _injectPlaybackIntentHooksIfNeeded() async {
    final controller = _webViewController;
    if (controller == null || _playbackIntentHooksInjected) {
      return;
    }

    try {
      await controller.evaluateJavascript(
        source: '''
          (() => {
            if (window.__mediaTubeIntentHooked) {
              return true;
            }

            window.__mediaTubeIntentHooked = true;

            const originalPause = HTMLMediaElement.prototype.pause;
            HTMLMediaElement.prototype.pause = function() {
              this.dataset.mtJsPauseTime = Date.now().toString();
              return originalPause.apply(this, arguments);
            };

            const markIntentFromState = (video) => {
              try {
                const pageHidden = document.hidden || document.visibilityState === 'hidden';

                if (video.ended) {
                  video.dataset.mtUserIntent = 'pause';
                  delete video.dataset.mtBackgroundPlay;
                  return;
                }

                if (!video.paused) {
                  video.dataset.mtUserIntent = 'play';
                  video.dataset.mtBackgroundPlay = 'true';
                  return;
                }

                if (video.dataset.mtUserIntent === 'play') {
                  const jsPauseTime = parseInt(video.dataset.mtJsPauseTime || '0', 10);
                  const timeSinceJsPause = Date.now() - jsPauseTime;
                  const isJsInitiated = timeSinceJsPause < 1000;
                  
                  // Keep play intent when pause happens while app/page is hidden,
                  // or if it was definitely a native system pause (not from JS).
                  if (pageHidden || !isJsInitiated || (video.currentTime || 0) > 0) {
                    video.dataset.mtBackgroundPlay = 'true';
                    return;
                  }
                }

                video.dataset.mtUserIntent = 'pause';
                delete video.dataset.mtBackgroundPlay;
              } catch (_) {}
            };

            const bindVideo = (video) => {
              if (!video || video.__mediaTubeIntentBound) {
                return;
              }

              video.__mediaTubeIntentBound = true;
              markIntentFromState(video);

              const markPlay = () => {
                try {
                  video.dataset.mtUserIntent = 'play';
                  video.dataset.mtBackgroundPlay = 'true';
                } catch (_) {}
              };

              const markPause = () => {
                try {
                  if (!video.ended) {
                    const pageHidden =
                      document.hidden || document.visibilityState === 'hidden';

                    const jsPauseTime = parseInt(video.dataset.mtJsPauseTime || '0', 10);
                    const timeSinceJsPause = Date.now() - jsPauseTime;
                    const isJsInitiated = timeSinceJsPause < 1000;

                    if ((pageHidden || !isJsInitiated) && video.dataset.mtUserIntent === 'play') {
                      // Keep intent if pause was caused by native/lifecycle interruption, not JS user tap.
                      video.dataset.mtBackgroundPlay = 'true';
                      return;
                    }

                    video.dataset.mtUserIntent = 'pause';
                    delete video.dataset.mtBackgroundPlay;
                  }
                } catch (_) {}
              };

              const markEnded = () => {
                try {
                  video.dataset.mtUserIntent = 'pause';
                  delete video.dataset.mtBackgroundPlay;
                } catch (_) {}
              };

              video.addEventListener('play', markPlay, { passive: true });
              video.addEventListener('playing', markPlay, { passive: true });
              video.addEventListener('pause', markPause, { passive: true });
              video.addEventListener('ended', markEnded, { passive: true });
            };

            const bindAllVideos = () => {
              document.querySelectorAll('video').forEach((video) => {
                bindVideo(video);
                markIntentFromState(video);
              });
            };

            bindAllVideos();

            if (!window.__mediaTubeIntentObserver) {
              const observer = new MutationObserver((mutations) => {
                let hasNewVideo = false;
                for (const m of mutations) {
                  if (m.addedNodes) {
                    for (const node of m.addedNodes) {
                      if (node.nodeName === 'VIDEO') {
                        hasNewVideo = true;
                        break;
                      }
                      if (node.querySelectorAll && node.querySelectorAll('video').length > 0) {
                        hasNewVideo = true;
                        break;
                      }
                    }
                  }
                  if (hasNewVideo) break;
                }
                if (hasNewVideo) bindAllVideos();
              });

              observer.observe(document.documentElement || document.body, {
                childList: true,
                subtree: true,
              });

              window.__mediaTubeIntentObserver = observer;
            }

            return true;
          })();
        ''',
      );

      _playbackIntentHooksInjected = true;
    } catch (e) {
      debugPrint('Playback intent hook injection failed: $e');
    }
  }

  Future<void> _injectPlaybackKeepAliveScript() async {
    final controller = _webViewController;
    if (controller == null || _keepAlivePlaybackScriptInjected) {
      return;
    }

    try {
      await controller.evaluateJavascript(
        source: '''
          (() => {
            if (window.__mediaTubeKeepAliveHooked) {
              return true;
            }

            window.__mediaTubeKeepAliveHooked = true;

            const keepPlaying = () => {
              const videos = Array.from(document.querySelectorAll('video'));
              videos.forEach((video) => {
                try {
                  if (video.ended) {
                    video.dataset.mtUserIntent = 'pause';
                    delete video.dataset.mtBackgroundPlay;
                    return;
                  }

                  if (video.dataset.mtUserIntent === 'pause') {
                    const pageHidden =
                      document.hidden || document.visibilityState === 'hidden';
                    const hasProgress = (video.currentTime || 0) > 0;

                    if (pageHidden && hasProgress) {
                      video.dataset.mtUserIntent = 'play';
                      video.dataset.mtBackgroundPlay = 'true';
                    } else {
                      delete video.dataset.mtBackgroundPlay;
                      return;
                    }
                  }

                  if (!video.paused) {
                    video.dataset.mtUserIntent = 'play';
                    video.dataset.mtBackgroundPlay = 'true';
                  }

                  // Only resume videos that were marked as playing by MediaTube
                  // before the app went to background.
                  if (video.dataset.mtBackgroundPlay !== 'true') {
                    return;
                  }

                  video.setAttribute('playsinline', 'true');
                  video.setAttribute('webkit-playsinline', 'true');
                  video.autoplay = true;
                  if (video.muted) {
                    video.muted = false;
                  }

                  if (video.paused) {
                    const playPromise = video.play();
                    if (playPromise && typeof playPromise.catch === 'function') {
                      playPromise.catch(() => {});
                    }
                  }
                } catch (_) {}
              });
            };

            ['visibilitychange', 'focus', 'pageshow', 'resume'].forEach((eventName) => {
              try {
                window.addEventListener(eventName, keepPlaying, { passive: true });
              } catch (_) {}
              try {
                document.addEventListener(eventName, keepPlaying, { passive: true });
              } catch (_) {}
            });

            try {
              document.addEventListener('play', keepPlaying, true);
            } catch (_) {}

            setInterval(() => {
              if (document.hidden) {
                keepPlaying();
              }
            }, 3200);

            return true;
          })();
        ''',
      );
      _keepAlivePlaybackScriptInjected = true;
    } catch (e) {
      debugPrint('Background keep-alive injection failed: $e');
    }
  }

  Future<void> _forceCurrentVideoPlayback({int delayMs = 0}) async {
    final controller = _webViewController;
    if (controller == null) {
      return;
    }

    final effectiveDelayMs = delayMs < 0 ? 0 : delayMs;

    try {
      await controller.evaluateJavascript(
        source:
            '''
          (() => {
            const delayMs = $effectiveDelayMs;

            const forcePlay = () => {
              const videos = Array.from(document.querySelectorAll('video'));
              if (!videos.length) {
                return 0;
              }

              let acted = 0;

              videos.forEach((video) => {
                try {
                  if (video.ended) {
                    video.dataset.mtUserIntent = 'pause';
                    delete video.dataset.mtBackgroundPlay;
                    return;
                  }

                  if (video.dataset.mtUserIntent === 'pause') {
                    const pageHidden =
                      document.hidden || document.visibilityState === 'hidden';
                    const hasProgress = (video.currentTime || 0) > 0;

                    if (pageHidden && hasProgress) {
                      video.dataset.mtUserIntent = 'play';
                      video.dataset.mtBackgroundPlay = 'true';
                    } else {
                      delete video.dataset.mtBackgroundPlay;
                      return;
                    }
                  }

                  // Mark currently playing videos for background continuation.
                  // Only videos that were playing (not paused by user) get marked.
                  if (!video.paused) {
                    video.dataset.mtUserIntent = 'play';
                    video.dataset.mtBackgroundPlay = 'true';
                  }

                  // Only resume videos marked for background play.
                  if (video.dataset.mtBackgroundPlay !== 'true') {
                    return;
                  }

                  video.setAttribute('playsinline', 'true');
                  video.setAttribute('webkit-playsinline', 'true');
                  video.autoplay = true;
                  if (video.muted) {
                    video.muted = false;
                  }

                  if (video.paused) {
                    const playPromise = video.play();
                    if (playPromise && typeof playPromise.catch === 'function') {
                      playPromise.catch(() => {});
                    }
                    acted += 1;
                  }
                } catch (_) {}
              });

              return acted;
            };

            if (delayMs > 0) {
              setTimeout(forcePlay, delayMs);
              return 0;
            }

            return forcePlay();
          })();
        ''',
      );
    } catch (e) {
      debugPrint('Background playback trigger failed: $e');
    }
  }

  Future<void> _checkClipboardForMedia() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim() ?? '';

      final urlRegex = RegExp(r'https?://[^\s]+');
      final match = urlRegex.firstMatch(text);
      if (match == null) return;

      String url = match.group(0)!;
      url = url.replaceAll(RegExp(r'[.,!?;:]+$'), '');

      final ytService = YouTubeService();
      if (!ytService.isValidYouTubeUrl(url)) return;

      if (!mounted) return;
      final downloadProvider = context.read<DownloadProvider>();

      // Check if already in active/history
      final exists =
          downloadProvider.allDownloadsHistory.any((task) => task.url == url) ||
          downloadProvider.activeDownloads.any((task) => task.url == url);

      if (exists || _currentUrl == url) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('YouTube link detected in clipboard.'),
          action: SnackBarAction(
            label: 'Load',
            onPressed: () {
              _loadUrl(url);
              _processPendingUrl(url);
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      debugPrint('Clipboard check error: $e');
    }
  }

  /// Reactively checks for and processes pending share-to-download URLs.
  /// Called whenever BrowserProvider notifies listeners.
  void _checkAndProcessPendingUrl() {
    if (!mounted || _isProcessingPendingUrl) return;
    final provider = _browserProviderRef;
    if (provider == null) return;
    final pendingUrl = provider.pendingUrl;
    if (pendingUrl == null) return;

    // Consume immediately to prevent re-processing
    provider.consumePendingUrl();
    _processPendingUrl(pendingUrl);
  }

  /// Processes a shared URL: pops any routes on top, fetches streams,
  /// shows media sheet, then navigates to Downloads.
  Future<void> _processPendingUrl(String url) async {
    _isProcessingPendingUrl = true;
    try {
      final normalized = ShareUrlService.normalizeSharedUrl(url) ?? url;
      if (!ShareUrlService.isSupportedWebUrl(normalized)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This shared link cannot be opened directly. Share a web URL from Facebook.',
              ),
            ),
          );
        }
        return;
      }

      // Pop any routes on top (DownloadsScreen, bottom sheets) so we're
      // back on BrowserScreen before showing the new media sheet.
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }

      // Small delay to let the pop animation settle
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;

      setState(() => _isShareToDownload = true);

      final browserProvider = Provider.of<BrowserProvider>(
        context,
        listen: false,
      );

      // Trigger detection for the shared URL.
      // For non-YouTube platforms this must load the page in WebView first.
      _loadUrl(normalized);
      browserProvider.setCurrentUrl(normalized);
      _currentUrl = normalized;

      // Start extraction immediately so shared links do not require manual retries.
      unawaited(
        browserProvider.refreshCurrentPlatformMedia(
          forceRefresh: true,
          runHeadlessExtractor: true,
        ),
      );

      // Retry once automatically if no streams are found from the first pass.
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        if (browserProvider.hasDetectedMedia ||
            browserProvider.isFetchingMedia) {
          return;
        }
        unawaited(
          browserProvider.refreshCurrentPlatformMedia(
            forceRefresh: false,
            runHeadlessExtractor: true,
          ),
        );
      });

      // Give the fetch a moment to start so the sheet shows loading state
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;

      // Show the media selection sheet
      await _showMediaSheet(context, browserProvider);

      // After sheet closes, navigate to Downloads screen or exit if share
      if (_isShareToDownload && mounted) {
        setState(() => _isShareToDownload = false);

        final hasActive = Provider.of<DownloadProvider>(
          context,
          listen: false,
        ).hasActiveDownloads;
        if (hasActive) {
          // A download was started via share! Pop back to previous app.
          try {
            const platform = MethodChannel('com.rajesh.mediatube/app');
            await platform.invokeMethod('moveToBackground');
          } catch (_) {
            SystemNavigator.pop();
          }
        } else {
          // User probably cancelled, stay in app or pop?
          // We'll just stay in app for safety.
        }
      }
    } finally {
      _isProcessingPendingUrl = false;
      // Re-check in case more URLs were queued while we were processing
      if (mounted) {
        _checkAndProcessPendingUrl();
      }
    }
  }

  bool _isWebViewReady = false; // Tracks if WebView is fully created
  bool _isUrlBarVisible = false;
  bool _isChromeVisible = true;
  Timer? _chromeAutoHideTimer;

  void _scheduleChromeAutoHide({Duration delay = const Duration(seconds: 3)}) {
    _chromeAutoHideTimer?.cancel();

    if (_showHomePage || _isUrlBarVisible) {
      return;
    }

    _chromeAutoHideTimer = Timer(delay, () {
      if (!mounted || _showHomePage || _isUrlBarVisible) {
        return;
      }
      if (_isChromeVisible) {
        setState(() {
          _isChromeVisible = false;
        });
      }
    });
  }

  void _showChrome({bool keepVisible = false}) {
    if (!_isChromeVisible) {
      setState(() {
        _isChromeVisible = true;
      });
    }

    if (!keepVisible) {
      _scheduleChromeAutoHide();
    }
  }

  void _toggleUrlBarVisibility() {
    final next = !_isUrlBarVisible;
    setState(() {
      _isUrlBarVisible = next;
      _isChromeVisible = true;
    });

    if (next) {
      _chromeAutoHideTimer?.cancel();
      _urlFocusNode.requestFocus();
    } else {
      _urlFocusNode.unfocus();
      _scheduleChromeAutoHide();
    }
  }

  void _loadUrl(String url) {
    if (url.isEmpty) return;

    final normalizedUrl = UrlInputSanitizer.sanitizeToNavigableUrl(url);
    if (normalizedUrl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open that link. Try a full URL like https://example.com'),
        ),
      );
      return;
    }

    setState(() {
      _currentUrl = normalizedUrl;
      _showHomePage = false;
      _isUrlBarVisible = false;
    });

    if (_isWebViewReady) {
      _webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(normalizedUrl)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // pendingUrl is now handled reactively via _checkAndProcessPendingUrl listener
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        
        if (_isOmniMenuExpanded) {
          _collapseOmniMenu();
          return;
        }

        if (_showHomePage) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          } else {
            SystemNavigator.pop();
          }
          return;
        }

        final canGoBack = await _webViewController?.canGoBack() ?? false;
        if (canGoBack) {
          await _webViewController?.goBack();
        } else {
          _goHome();
        }
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            final safePadding = MediaQuery.viewPaddingOf(context);

          return Consumer<BrowserProvider>(
            builder: (context, browserProvider, _) {
              return Stack(
                children: [
                  // WebView layer
                  Positioned.fill(
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          // Top URL indicator bar (only when browsing)
                          if (!_showHomePage)
                            _buildTopUrlIndicator(
                              context,
                              currentUrl: _urlController.text,
                            ),
                          // WebView
                          Expanded(
                            child: Offstage(
                              offstage: _showHomePage,
                              child: _buildWebView(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Home screen overlay
                  if (_showHomePage)
                    Positioned.fill(
                      child: SafeArea(
                        child: HomeScreen(
                          onNavigate: _loadUrl,
                        ),
                      ),
                    ),
                  // Bottom chrome navigation bar
                  if (!_showHomePage)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildBottomChrome(
                        canGoBack: browserProvider.canGoBack,
                        canGoForward: browserProvider.canGoForward,
                        isLoading: browserProvider.isLoading,
                      ),
                    ),
                  // Omni menu scrim
                  if (_isOmniMenuExpanded || _omniMenuController.value > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_isOmniMenuExpanded,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _collapseOmniMenu,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  // Omni menu action items (expand from the pill dock position)
                  ..._buildOmniMenuActions(
                    anchor: Offset(
                      viewport.width / 2 - _omniFabSize / 2,
                      viewport.height - safePadding.bottom - 80 - _omniFabSize,
                    ),
                    viewport: viewport,
                    safePadding: safePadding,
                  ),
                  // Unified pill dock at bottom center
                  if (!_showHomePage)
                    _buildUnifiedPillDock(
                      viewport: viewport,
                      safePadding: safePadding,
                      hasDetectedMedia: browserProvider.hasDetectedMedia,
                      isYouTubePage: browserProvider.isYouTubePage,
                      hasFetchError: browserProvider.hasFetchError,
                      isFetchingMedia: browserProvider.isFetchingMedia,
                      mediaCount: browserProvider.detectedMedia.length,
                    ),
                ],
              );
            },
          );
        },
      ),
    ));
  }

  // ignore: unused_element
  Widget _buildDraggableOmniFab({
    required Offset position,
    required Size viewport,
    required EdgeInsets safePadding,
  }) {
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        onTap: _toggleOmniMenu,
        onPanStart: (_) {
          if (_isOmniMenuExpanded) {
            _collapseOmniMenu();
          }
        },
        onPanUpdate: (details) =>
            _onOmniFabDragged(details, viewport, safePadding),
        onPanEnd: (_) => _persistFloatingButtonPositions(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: _omniFabSize,
          height: _omniFabSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF2D2D), Color(0xFFE50914)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(90),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            _isOmniMenuExpanded ? Icons.close_rounded : Icons.menu_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildOmniMenuActions({
    required Offset anchor,
    required Size viewport,
    required EdgeInsets safePadding,
  }) {
    if (!_isOmniMenuExpanded && _omniMenuController.value <= 0) {
      return const <Widget>[];
    }

    final actions = <_OmniMenuAction>[
      _OmniMenuAction(
        icon: Icons.download_rounded,
        label: 'Downloads',
        onTap: () => _openDownloadsScreen(context),
      ),
      _OmniMenuAction(
        icon: Icons.settings_rounded,
        label: 'Settings',
        onTap: () => _openSettingsScreen(context),
      ),
      _OmniMenuAction(
        icon: Icons.refresh_rounded,
        label: 'Refresh',
        onTap: () => _webViewController?.reload(),
      ),
      _OmniMenuAction(
        icon: Icons.home_rounded,
        label: 'Home',
        onTap: _goHome,
      ),
    ];

    final expandsDownward = anchor.dy < safePadding.top + 190;
    final baseTop = anchor.dy + (_omniFabSize - _omniActionHeight) / 2;
    final baseLeft = (anchor.dx + (_omniFabSize - _omniActionWidth) / 2)
        .clamp(
          safePadding.left + 8,
          viewport.width - safePadding.right - _omniActionWidth - 8,
        )
        .toDouble();

    final items = <Widget>[];

    for (var i = 0; i < actions.length; i++) {
      final step = (i + 1) * (_omniActionHeight + 10);
      final rawTargetTop = expandsDownward ? baseTop + step : baseTop - step;
      final targetTop = rawTargetTop
          .clamp(
            safePadding.top + 8,
            viewport.height - safePadding.bottom - _omniActionHeight - 8,
          )
          .toDouble();

      final intervalStart = (i * 0.1).clamp(0.0, 0.6).toDouble();
      final itemAnimation = CurvedAnimation(
        parent: _omniMenuController,
        curve: Interval(intervalStart, 1, curve: Curves.easeOutBack),
      );

      items.add(
        AnimatedBuilder(
          animation: itemAnimation,
          builder: (context, child) {
            final t = itemAnimation.value;
            final animatedTop = baseTop + (targetTop - baseTop) * t;
            return Positioned(
              left: baseLeft,
              top: animatedTop,
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.85 + (0.15 * t),
                  child: IgnorePointer(ignoring: t < 0.95, child: child),
                ),
              ),
            );
          },
          child: _buildOmniActionChip(actions[i]),
        ),
      );
    }

    return items;
  }

  Widget _buildOmniActionChip(_OmniMenuAction action) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withAlpha(245),
      elevation: 8,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          _collapseOmniMenu();
          action.onTap();
        },
        child: SizedBox(
          width: _omniActionWidth,
          height: _omniActionHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, size: 20),
              const SizedBox(width: 8),
              Text(
                action.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleOmniMenu() {
    if (_isOmniMenuExpanded) {
      _collapseOmniMenu();
      return;
    }

    setState(() {
      _isOmniMenuExpanded = true;
    });
    _omniMenuController.forward(from: 0);
  }

  void _collapseOmniMenu() {
    if (!_isOmniMenuExpanded && _omniMenuController.value <= 0) {
      return;
    }

    setState(() {
      _isOmniMenuExpanded = false;
    });
    _omniMenuController.reverse();
  }

  void _onOmniFabDragged(
    DragUpdateDetails details,
    Size viewport,
    EdgeInsets safePadding,
  ) {
    final currentAbsolute = _normalizedToAbsolute(
      _omniFabNormalized,
      viewport,
      safePadding,
      _omniFabSize,
    );
    final nextAbsolute = _clampAbsoluteOffset(
      currentAbsolute + details.delta,
      viewport,
      safePadding,
      _omniFabSize,
    );

    setState(() {
      _omniFabNormalized = _absoluteToNormalized(
        nextAbsolute,
        viewport,
        safePadding,
        _omniFabSize,
      );
    });
  }

  Future<void> _loadFloatingButtonPositions() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    final prefs = _cachedPrefs!;
    final omniX = prefs.getDouble(_omniFabXPrefKey);
    final omniY = prefs.getDouble(_omniFabYPrefKey);
    final streamX = prefs.getDouble(_streamFabXPrefKey);
    final streamY = prefs.getDouble(_streamFabYPrefKey);

    if (!mounted) {
      return;
    }

    setState(() {
      if (omniX != null && omniY != null) {
        _omniFabNormalized = Offset(
          omniX.clamp(0.0, 1.0).toDouble(),
          omniY.clamp(0.0, 1.0).toDouble(),
        );
      }

      if (streamX != null && streamY != null) {
        _streamFabNormalized = Offset(
          streamX.clamp(0.0, 1.0).toDouble(),
          streamY.clamp(0.0, 1.0).toDouble(),
        );
      }
    });
  }

  void _persistFloatingButtonPositions() {
    _fabPersistDebounce?.cancel();
    _fabPersistDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_saveFloatingButtonPositions());
    });
  }

  Future<void> _saveFloatingButtonPositions() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    final prefs = _cachedPrefs!;
    await prefs.setDouble(_omniFabXPrefKey, _omniFabNormalized.dx);
    await prefs.setDouble(_omniFabYPrefKey, _omniFabNormalized.dy);
    await prefs.setDouble(_streamFabXPrefKey, _streamFabNormalized.dx);
    await prefs.setDouble(_streamFabYPrefKey, _streamFabNormalized.dy);
  }

  Offset _normalizedToAbsolute(
    Offset normalized,
    Size viewport,
    EdgeInsets safePadding,
    double controlSize,
  ) {
    final usableWidth = math.max(
      1.0,
      viewport.width - safePadding.horizontal - controlSize - 16,
    );
    final usableHeight = math.max(
      1.0,
      viewport.height - safePadding.vertical - controlSize - 16,
    );

    final x =
        safePadding.left + 8 + normalized.dx.clamp(0.0, 1.0) * usableWidth;
    final y =
        safePadding.top + 8 + normalized.dy.clamp(0.0, 1.0) * usableHeight;
    return Offset(x.toDouble(), y.toDouble());
  }

  Offset _absoluteToNormalized(
    Offset absolute,
    Size viewport,
    EdgeInsets safePadding,
    double controlSize,
  ) {
    final usableWidth = math.max(
      1.0,
      viewport.width - safePadding.horizontal - controlSize - 16,
    );
    final usableHeight = math.max(
      1.0,
      viewport.height - safePadding.vertical - controlSize - 16,
    );

    final nx = ((absolute.dx - safePadding.left - 8) / usableWidth)
        .clamp(0.0, 1.0)
        .toDouble();
    final ny = ((absolute.dy - safePadding.top - 8) / usableHeight)
        .clamp(0.0, 1.0)
        .toDouble();
    return Offset(nx, ny);
  }

  Offset _clampAbsoluteOffset(
    Offset absolute,
    Size viewport,
    EdgeInsets safePadding,
    double controlSize,
  ) {
    final minX = safePadding.left + 8;
    final minY = safePadding.top + 8;
    final maxX = math.max(
      minX,
      viewport.width - safePadding.right - controlSize - 8,
    );
    final maxY = math.max(
      minY,
      viewport.height - safePadding.bottom - controlSize - 8,
    );

    return Offset(
      absolute.dx.clamp(minX, maxX).toDouble(),
      absolute.dy.clamp(minY, maxY).toDouble(),
    );
  }

  void _syncStreamPulseState(bool shouldPulse) {
    if (_isStreamPulseActive == shouldPulse) {
      return;
    }

    _isStreamPulseActive = shouldPulse;

    if (shouldPulse) {
      _streamPulseController.repeat(reverse: true);
      return;
    }

    _streamPulseController.stop();
    _streamPulseController.value = 0;
  }

  // ignore: unused_element
  Widget _buildDraggableStreamFab({
    required Offset position,
    required Size viewport,
    required EdgeInsets safePadding,
    required bool hasDetectedMedia,
    required bool isYouTubePage,
    required bool hasFetchError,
    required bool isFetchingMedia,
  }) {
    final theme = Theme.of(context);
    final baseColor = isFetchingMedia
        ? Colors.orange
        : hasDetectedMedia
        ? Colors.green.shade600
        : hasFetchError
        ? Colors.orange.shade700
        : isYouTubePage
        ? const Color(0xFFE50914)
        : theme.colorScheme.primary;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        onPanUpdate: (details) =>
            _onStreamFabDragged(details, viewport, safePadding),
        onPanEnd: (_) => _persistFloatingButtonPositions(),
        onTap: () {
          if (isFetchingMedia) {
            return;
          }

          final provider = context.read<BrowserProvider>();
          if (!hasDetectedMedia) {
            unawaited(
              provider.refreshCurrentPlatformMedia(
                forceRefresh: true,
                runHeadlessExtractor: true,
              ),
            );
          }
          _showMediaSheet(context, provider);
        },
        child: AnimatedBuilder(
          animation: _streamPulseController,
          builder: (context, _) {
            final pulse = _isStreamPulseActive
                ? _streamPulseController.value
                : 0.0;
            final scale = 1 + (0.12 * pulse);
            final color =
                Color.lerp(baseColor, Colors.white, 0.16 * pulse) ?? baseColor;

            return Transform.scale(
              scale: scale,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: _streamFabSize,
                height: _streamFabSize,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(70),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Center(
                  child: isFetchingMedia
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          hasFetchError
                              ? Icons.refresh_rounded
                              : hasDetectedMedia
                              ? Icons.download_rounded
                              : Icons.download_for_offline_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _onStreamFabDragged(
    DragUpdateDetails details,
    Size viewport,
    EdgeInsets safePadding,
  ) {
    final currentAbsolute = _normalizedToAbsolute(
      _streamFabNormalized,
      viewport,
      safePadding,
      _streamFabSize,
    );
    final nextAbsolute = _clampAbsoluteOffset(
      currentAbsolute + details.delta,
      viewport,
      safePadding,
      _streamFabSize,
    );

    setState(() {
      _streamFabNormalized = _absoluteToNormalized(
        nextAbsolute,
        viewport,
        safePadding,
        _streamFabSize,
      );
    });
  }

  void _openSettingsScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }

  // Top URL indicator — slim bar showing current domain, tap to edit URL
  Widget _buildTopUrlIndicator(BuildContext context, {required String currentUrl}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Extract domain for display
    String displayText = currentUrl;
    try {
      final uri = Uri.tryParse(currentUrl);
      if (uri != null && uri.host.isNotEmpty) {
        final isSecure = uri.scheme == 'https';
        displayText = '${isSecure ? '🔒 ' : ''}${uri.host}';
      }
    } catch (_) {}

    if (!_isUrlBarVisible) {
      // Collapsed: show domain pill
      return GestureDetector(
        onTap: _toggleUrlBarVisibility,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1A1A24)
                : Colors.white,
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? Colors.white.withAlpha(15)
                    : Colors.black.withAlpha(12),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                currentUrl.startsWith('https')
                    ? Icons.lock_rounded
                    : Icons.language_rounded,
                size: 14,
                color: currentUrl.startsWith('https')
                    ? Colors.green.shade400
                    : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  displayText,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white60 : Colors.black54,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.edit_rounded,
                size: 14,
                color: isDark ? Colors.white30 : Colors.black26,
              ),
            ],
          ),
        ),
      );
    }

    // Expanded: full URL editing bar
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A24) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white.withAlpha(15) : Colors.black.withAlpha(12),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withAlpha(15)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : Colors.grey.shade600,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Search or enter URL',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (text) {
                        _loadUrl(text);
                        _toggleUrlBarVisibility();
                      },
                    ),
                  ),
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _urlController.clear();
                        _urlFocusNode.requestFocus();
                      },
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: _toggleUrlBarVisibility,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }

  /// Unified pill-shaped dock at the bottom of the screen.
  /// Combines the omni-menu button and download/media button into one.
  Widget _buildUnifiedPillDock({
    required Size viewport,
    required EdgeInsets safePadding,
    required bool hasDetectedMedia,
    required bool isYouTubePage,
    required bool hasFetchError,
    required bool isFetchingMedia,
    required int mediaCount,
  }) {
    _syncStreamPulseState(isFetchingMedia);

    final showMediaAction = hasDetectedMedia || isFetchingMedia || isYouTubePage || hasFetchError;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine download button color
    final downloadColor = isFetchingMedia
        ? Colors.orange
        : hasDetectedMedia
            ? Colors.green.shade600
            : hasFetchError
                ? Colors.orange.shade700
                : const Color(0xFFE50914);

    return Positioned(
      bottom: safePadding.bottom + 68, // above bottom chrome
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1C1C28), Color(0xFF14141C)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(100),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Menu button
              GestureDetector(
                onTap: _toggleOmniMenu,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _isOmniMenuExpanded
                        ? null
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFF2D2D), Color(0xFFE50914)],
                          ),
                    color: _isOmniMenuExpanded
                        ? (isDark ? Colors.white.withAlpha(25) : Colors.grey.shade300)
                        : null,
                  ),
                  child: Icon(
                    _isOmniMenuExpanded ? Icons.close_rounded : Icons.menu_rounded,
                    color: _isOmniMenuExpanded
                        ? (isDark ? Colors.white70 : Colors.black54)
                        : Colors.white,
                    size: 24,
                  ),
                ),
              ),
              // Download / media button — only visible when relevant
              if (showMediaAction) ...[  
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    if (isFetchingMedia) return;
                    final provider = context.read<BrowserProvider>();
                    if (!hasDetectedMedia) {
                      unawaited(
                        provider.refreshCurrentPlatformMedia(
                          forceRefresh: true,
                          runHeadlessExtractor: true,
                        ),
                      );
                    }
                    _showMediaSheet(context, provider);
                  },
                  child: AnimatedBuilder(
                    animation: _streamPulseController,
                    builder: (context, _) {
                      final pulse = _isStreamPulseActive
                          ? _streamPulseController.value
                          : 0.0;
                      final scale = 1 + (0.08 * pulse);
                      final btnColor = Color.lerp(
                            downloadColor, Colors.white, 0.12 * pulse) ??
                          downloadColor;

                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          height: 46,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: btnColor,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isFetchingMedia)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              else
                                Icon(
                                  hasFetchError
                                      ? Icons.refresh_rounded
                                      : Icons.download_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              if (hasDetectedMedia && mediaCount > 0) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '$mediaCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTopChrome({
    required String currentUrl,
    required int tabCount,
    required bool canGoForward,
    required bool isLoading,
  }) {
    final showChrome = _isChromeVisible || _isUrlBarVisible;
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      height: showChrome ? (_isUrlBarVisible ? 112 : 58) : 0,
      child: ClipRect(
        child: IgnorePointer(
          ignoring: !showChrome,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withAlpha(245),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withAlpha(130),
                ),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 12,
                    color: Color(0x1A000000),
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.play_circle_fill_rounded,
                          color: Color(0xFFFF0000),
                          size: 26,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'YouTube',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.1,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: _isUrlBarVisible
                              ? 'Hide address bar'
                              : 'Search or URL',
                          icon: Icon(
                            _isUrlBarVisible ? Icons.close : Icons.search,
                          ),
                          onPressed: _toggleUrlBarVisibility,
                        ),
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Tabs',
                              icon: const Icon(Icons.filter_none),
                              onPressed: () {
                                _showChrome(keepVisible: true);
                                _showTabsSheet(
                                  context,
                                  context.read<BrowserProvider>(),
                                );
                              },
                            ),
                            Positioned(
                              child: IgnorePointer(
                                child: Text(
                                  '$tabCount',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          tooltip: 'More controls',
                          icon: const Icon(Icons.more_vert),
                          onPressed: () {
                            _showChrome(keepVisible: true);
                            _showQuickActionsSheet(
                              canGoForward: canGoForward,
                              isLoading: isLoading,
                              currentUrl: currentUrl,
                            );
                          },
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  if (_isUrlBarVisible)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: _buildUrlBar(
                        currentUrl: currentUrl,
                        tabCount: tabCount,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomChrome({
    required bool canGoBack,
    required bool canGoForward,
    required bool isLoading,
  }) {
    final visible = _isChromeVisible && !_showHomePage;
    final theme = Theme.of(context);

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, 1.2),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withAlpha(245),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withAlpha(130),
                ),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 14,
                    color: Color(0x22000000),
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: canGoBack
                        ? () {
                            _webViewController?.goBack();
                            _showChrome();
                          }
                        : null,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  ),
                  IconButton(
                    tooltip: 'Forward',
                    onPressed: canGoForward
                        ? () {
                            _webViewController?.goForward();
                            _showChrome();
                          }
                        : null,
                    icon: const Icon(Icons.arrow_forward_ios_rounded),
                  ),
                  IconButton(
                    tooltip: 'Home shortcuts',
                    onPressed: _goHome,
                    icon: const Icon(Icons.home_rounded),
                  ),
                  IconButton(
                    tooltip: isLoading ? 'Stop loading' : 'Refresh',
                    onPressed: () {
                      if (isLoading) {
                        _webViewController?.stopLoading();
                      } else {
                        _webViewController?.reload();
                      }
                      _showChrome();
                    },
                    icon: Icon(
                      isLoading ? Icons.close_rounded : Icons.refresh_rounded,
                    ),
                  ),
                  Consumer<DownloadProvider>(
                    builder: (context, downloadProvider, _) {
                      return Stack(
                        children: [
                          IconButton(
                            tooltip: 'Downloads',
                            onPressed: () {
                              _openDownloadsScreen(context);
                              _showChrome(keepVisible: true);
                            },
                            icon: const Icon(Icons.download_rounded),
                          ),
                          if (downloadProvider.hasActiveDownloads)
                            Positioned(
                              right: 8,
                              top: 8,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'More controls',
                    onPressed: () {
                      _showChrome(keepVisible: true);
                      _showQuickActionsSheet(
                        canGoForward: canGoForward,
                        isLoading: isLoading,
                        currentUrl: _urlController.text,
                      );
                    },
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showQuickActionsSheet({
    required bool canGoForward,
    required bool isLoading,
    required String currentUrl,
  }) async {
    final provider = context.read<BrowserProvider>();
    final canGoBack = provider.canGoBack;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('Search or enter URL'),
                subtitle: Text(
                  currentUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (!_isUrlBarVisible) {
                    _toggleUrlBarVisibility();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.filter_none),
                title: const Text('Manage tabs'),
                onTap: () {
                  Navigator.pop(context);
                  _showTabsSheet(this.context, provider);
                },
              ),
              ListTile(
                leading: const Icon(Icons.arrow_back),
                enabled: canGoBack,
                title: const Text('Go back'),
                onTap: canGoBack
                    ? () {
                        Navigator.pop(context);
                        _webViewController?.goBack();
                      }
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.arrow_forward),
                enabled: canGoForward,
                title: const Text('Go forward'),
                onTap: canGoForward
                    ? () {
                        Navigator.pop(context);
                        _webViewController?.goForward();
                      }
                    : null,
              ),
              ListTile(
                leading: Icon(isLoading ? Icons.close : Icons.refresh),
                title: Text(isLoading ? 'Stop loading' : 'Refresh page'),
                onTap: () {
                  Navigator.pop(context);
                  if (isLoading) {
                    _webViewController?.stopLoading();
                  } else {
                    _webViewController?.reload();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.home_rounded),
                title: const Text('Open quick sites'),
                onTap: () {
                  Navigator.pop(context);
                  _goHome();
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Open downloads'),
                onTap: () {
                  Navigator.pop(context);
                  _openDownloadsScreen(this.context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    _scheduleChromeAutoHide();
  }

  Widget _buildWebView() {
    return Stack(
      children: [
        RepaintBoundary(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: _youtubeVisibilityBypassScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ]),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: false,
              supportMultipleWindows: false,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              allowBackgroundAudioPlaying: true,
              useShouldInterceptRequest: _requestInterceptionEnabled,
              useWideViewPort: true,
              loadWithOverviewMode: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              safeBrowsingEnabled: true,
              allowFileAccess: false,
              allowContentAccess: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
              // Performance optimizations
              cacheEnabled: true,
              cacheMode: CacheMode.LOAD_DEFAULT,
              hardwareAcceleration: true,
              thirdPartyCookiesEnabled: true,
              userAgent:
                  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              _isWebViewReady = true;
              _startForegroundPlaybackIntentPolling();

              final provider = context.read<BrowserProvider>();
              unawaited(_syncRequestInterceptionMode(provider, force: true));
            },
            onLoadStart: (controller, url) {
              final provider = context.read<BrowserProvider>();
              provider.setLoading(true);
              _keepAlivePlaybackScriptInjected = false;
              _playbackIntentHooksInjected = false;
              _lastForegroundPlaybackIntentPlay = false;
              unawaited(_syncRequestInterceptionMode(provider));
              _urlController.text = url?.toString() ?? '';
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final rawUrl = navigationAction.request.url?.toString() ?? '';
              if (rawUrl.isEmpty) {
                return NavigationActionPolicy.ALLOW;
              }

              final uri = Uri.tryParse(rawUrl);
              final scheme = uri?.scheme.toLowerCase();
              if (scheme == 'http' || scheme == 'https') {
                if (uri == null || uri.host.isEmpty) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              }

              if (scheme == null) {
                return NavigationActionPolicy.CANCEL;
              }

              final normalizedUrl = ShareUrlService.normalizeSharedUrl(rawUrl);
              if (normalizedUrl != null &&
                  ShareUrlService.isSupportedWebUrl(normalizedUrl) &&
                  UrlInputSanitizer.isHttpOrHttpsUrl(normalizedUrl)) {
                controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(normalizedUrl)),
                );
              }

              return NavigationActionPolicy.CANCEL;
            },
            onLoadStop: (controller, url) async {
              final provider = context.read<BrowserProvider>();
              provider.setLoading(false);

              // For non-YouTube platforms, run a quick DOM scan for media URLs
              // because many platforms hide direct links behind dynamic scripts.
              try {
                if (!provider.isYouTubePage) {
                  final result = await controller.evaluateJavascript(
                    source: '''
                      (function() {
                        var urls = [];
                        function pushIfValid(u) {
                          if (!u || typeof u !== 'string') return;
                          if (u.startsWith('http')) urls.push(u);
                        }

                        var videos = document.getElementsByTagName('video');
                        for (var i = 0; i < videos.length; i++) {
                          pushIfValid(videos[i].src);
                          pushIfValid(videos[i].currentSrc);
                          var sources = videos[i].getElementsByTagName('source');
                          for (var j = 0; j < sources.length; j++) {
                            pushIfValid(sources[j].src);
                          }
                        }

                        var metas = document.getElementsByTagName('meta');
                        for (var k = 0; k < metas.length; k++) {
                          var p = (metas[k].getAttribute('property') || '').toLowerCase();
                          if (p === 'og:video' || p === 'og:video:url' || p === 'og:video:secure_url') {
                            pushIfValid(metas[k].getAttribute('content'));
                          }
                        }

                        return Array.from(new Set(urls));
                      })();
                    ''',
                  );

                  if (result is List) {
                    provider.addExtractedMediaUrls(
                      result.map((e) => e.toString()).toList(),
                    );
                  }

                  if (provider.isSocialVideoPage &&
                      !provider.hasDetectedMedia &&
                      !provider.isFetchingMedia) {
                    provider.refreshCurrentPlatformMedia(
                      forceRefresh: false,
                      runHeadlessExtractor: true,
                    );
                  }
                }
              } catch (e) {
                debugPrint('DOM media scan failed: $e');
              }

              // Update navigation state
              final canGoBack = await controller.canGoBack();
              final canGoForward = await controller.canGoForward();
              provider.setNavigationState(
                canGoBack: canGoBack,
                canGoForward: canGoForward,
              );

              if (provider.isYouTubePage) {
                unawaited(_injectPlaybackIntentHooksIfNeeded());
                unawaited(_injectPlaybackKeepAliveScript());
                unawaited(_refreshForegroundPlaybackIntentFromWebView());
              }

              unawaited(_syncRequestInterceptionMode(provider));
            },
            onTitleChanged: (controller, title) {
              context.read<BrowserProvider>().setPageTitle(title ?? '');
            },
            onLoadResource: (controller, resource) {
              final provider = context.read<BrowserProvider>();
              if (!provider.shouldObserveNetworkMedia) {
                return;
              }

              final dynamic raw = resource;
              final url = raw.url?.toString() ?? '';
              if (url.isEmpty) {
                return;
              }

              String? contentTypeHint;
              int? contentLengthHint;

              try {
                final dynamic typeValue = raw.contentType;
                if (typeValue is String && typeValue.isNotEmpty) {
                  contentTypeHint = typeValue;
                }
              } catch (_) {}

              try {
                final dynamic lengthValue = raw.contentLength;
                if (lengthValue is int && lengthValue > 0) {
                  contentLengthHint = lengthValue;
                } else if (lengthValue is String) {
                  final parsed = int.tryParse(lengthValue);
                  if (parsed != null && parsed > 0) {
                    contentLengthHint = parsed;
                  }
                }
              } catch (_) {}

              try {
                final dynamic responseHeaders = raw.responseHeaders;
                if (responseHeaders is Map) {
                  String? lookupHeader(String key) {
                    final lowerKey = key.toLowerCase();
                    for (final entry in responseHeaders.entries) {
                      final headerKey = entry.key.toString().toLowerCase();
                      if (headerKey == lowerKey) {
                        return entry.value?.toString();
                      }
                    }
                    return null;
                  }

                  contentTypeHint ??= lookupHeader('content-type');

                  final lengthFromHeader = lookupHeader('content-length');
                  if (contentLengthHint == null &&
                      lengthFromHeader != null &&
                      lengthFromHeader.isNotEmpty) {
                    final parsed = int.tryParse(lengthFromHeader);
                    if (parsed != null && parsed > 0) {
                      contentLengthHint = parsed;
                    }
                  }
                }
              } catch (_) {}

              provider.onResourceLoaded(
                url,
                contentType: contentTypeHint,
                contentLength: contentLengthHint,
              );
            },
            shouldInterceptRequest: (controller, request) async {
              final provider = context.read<BrowserProvider>();
              if (!provider.shouldObserveNetworkMedia) {
                return null;
              }

              final url = request.url.toString();
              if (url.isEmpty) return null;

              String? contentTypeHint;
              final acceptHeader =
                  request.headers?['Accept'] ?? request.headers?['accept'];
              if (acceptHeader != null && acceptHeader.isNotEmpty) {
                contentTypeHint = acceptHeader;
              }

              final fetchDest =
                  request.headers?['Sec-Fetch-Dest'] ??
                  request.headers?['sec-fetch-dest'];
              if (fetchDest == 'video') {
                contentTypeHint = 'video/mp4';
              } else if (fetchDest == 'audio') {
                contentTypeHint = 'audio/mpeg';
              }

              provider.onResourceLoaded(url, contentType: contentTypeHint);

              return null;
            },
            onUpdateVisitedHistory: (controller, url, isReload) {
              final urlStr = url?.toString() ?? '';
              if (urlStr.isNotEmpty) {
                final provider = context.read<BrowserProvider>();
                provider.setCurrentUrl(urlStr);
                unawaited(_syncRequestInterceptionMode(provider));
                _urlController.text = urlStr;
              }
            },
            onProgressChanged: (controller, progress) {
              context.read<BrowserProvider>().setLoading(progress < 100);
            },
          ),
        ),

        // Loading indicator - Rebuilds ONLY when isLoading changes
        Selector<BrowserProvider, bool>(
          selector: (_, provider) => provider.isLoading,
          builder: (context, isLoading, child) => isLoading
              ? const LinearProgressIndicator()
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  void _goHome() {
    setState(() {
      _showHomePage = true;
      _isUrlBarVisible = false;
      _isChromeVisible = true;
      _lastForegroundPlaybackIntentPlay = false;
      // Don't destroy WebView — keep it alive offstage for instant return.
    });
    _chromeAutoHideTimer?.cancel();
    _urlController.text = '';
  }

  Widget _buildUrlBar({required String currentUrl, required int tabCount}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    currentUrl.startsWith('https')
                        ? Icons.search
                        : Icons.language,
                    size: 18,
                    color: currentUrl.startsWith('https')
                        ? null
                        : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Search YouTube or enter URL',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _loadUrl,
                    ),
                  ),
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _urlController.clear();
                        _urlFocusNode.requestFocus();
                      },
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Tabs Button
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.filter_none),
                onPressed: () =>
                    _showTabsSheet(context, context.read<BrowserProvider>()),
              ),
              Positioned(
                child: IgnorePointer(
                  child: Text(
                    '$tabCount',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showTabsSheet(BuildContext context, BrowserProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tabs (${provider.tabs.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          provider.addNewTab();
                          Navigator.pop(context);
                          _loadUrl('https://m.youtube.com');
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Consumer<BrowserProvider>(
                    builder: (context, currentProvider, _) {
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: currentProvider.tabs.length,
                        itemBuilder: (context, index) {
                          final tab = currentProvider.tabs[index];
                          final isActive =
                              index == currentProvider.activeTabIndex;
                          return ListTile(
                            leading: Icon(
                              Icons.public,
                              color: isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              tab.title.isEmpty ? tab.url : tab.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isActive
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                            subtitle: Text(
                              tab.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                currentProvider.closeTab(index);
                                if (currentProvider.tabs.isEmpty) {
                                  Navigator.pop(context);
                                }
                              },
                            ),
                            onTap: () {
                              currentProvider.switchTab(index);
                              Navigator.pop(context);
                              _loadUrl(
                                currentProvider.currentUrl,
                              ); // re-trigger load for context
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showMediaSheet(
    BuildContext context,
    BrowserProvider browserProvider,
  ) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ChangeNotifierProvider.value(
        value: browserProvider,
        child: const _CachedMediaSheet(),
      ),
    );
  }

  void _openDownloadsScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DownloadsScreen()),
    );
  }
}

class _CachedMediaSheet extends StatelessWidget {
  const _CachedMediaSheet();

  @override
  Widget build(BuildContext context) {
    return Selector<
      BrowserProvider,
      ({
        int mediaVersion,
        bool isYouTube,
        bool isFetching,
        String? errorMessage,
      })
    >(
      selector: (_, browserProvider) {
        return (
          mediaVersion: browserProvider.mediaStateVersion,
          isYouTube: browserProvider.isYouTubePage,
          isFetching: browserProvider.isFetchingMedia,
          errorMessage: browserProvider.fetchError,
        );
      },
      builder: (context, state, _) {
        final browserProvider = context.read<BrowserProvider>();
        return MediaSelectionSheet(
          media: browserProvider.detectedMedia,
          isYouTube: state.isYouTube,
          isFetching: state.isFetching,
          errorMessage: state.errorMessage,
          onRefresh: () {
            context.read<BrowserProvider>().refreshCurrentPlatformMedia(
              forceRefresh: true,
            );
          },
        );
      },
    );
  }
}

class _OmniMenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _OmniMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}
