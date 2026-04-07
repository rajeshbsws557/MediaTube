import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../services/services.dart';

class YoutubePlaybackScreen extends StatefulWidget {
  final DetectedMedia media;
  final bool autoBackgroundStart;

  const YoutubePlaybackScreen({
    super.key,
    required this.media,
    this.autoBackgroundStart = true,
  });

  static Future<T?> pushBackground<T>({
    required NavigatorState navigator,
    required DetectedMedia media,
  }) {
    return navigator.push<T>(
      MaterialPageRoute(
        builder: (_) => YoutubePlaybackScreen(media: media),
      ),
    );
  }

  @override
  State<YoutubePlaybackScreen> createState() => _YoutubePlaybackScreenState();
}

class _YoutubePlaybackScreenState extends State<YoutubePlaybackScreen>
    with WidgetsBindingObserver {
  static const int _maxAutoBackgroundAttempts = 6;
  static const Duration _autoBackgroundRetryDelay = Duration(milliseconds: 700);
  static const Duration _uiRefreshInterval = Duration(milliseconds: 320);
  static const Duration _runtimeSyncInterval = Duration(milliseconds: 900);
  static const Duration _backgroundLifecycleDebounce = Duration(milliseconds: 180);
  static const Duration _backgroundRecoveryDelay = Duration(milliseconds: 220);

  VideoPlayerController? _controller;
  bool _isInitializing = true;
  bool _hasError = false;
  String? _errorText;

  final AndroidPlaybackBridgeService _nativePlaybackBridge =
    AndroidPlaybackBridgeService();
  StreamSubscription<NativePlaybackControlEvent>? _nativeControlSubscription;

  DateTime _lastUiRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNativeRuntimeSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _lastKnownIsPlaying;
  bool _hasAutoBackgroundHandoff = false;
  bool _autoBackgroundHandoffInProgress = false;
  int _autoBackgroundAttemptCount = 0;
  Timer? _autoBackgroundRetryTimer;
  bool _isDisposed = false;
  bool _allowBackgroundContinuation = true;
  bool _isHandlingLifecycleBackgroundTransition = false;
  DateTime _lastLifecycleBackgroundHandledAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  bool _didStopMediaSessionAfterCompletion = false;
  int _activePlaybackSessionId = 0;

  bool? _lastConfiguredPipEnabled;
  bool? _lastConfiguredPipAutoEnter;
  int? _lastConfiguredPipAspectWidth;
  int? _lastConfiguredPipAspectHeight;

  bool get _isAudioOnly => widget.media.type == MediaType.audio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_nativePlaybackBridge.ensureListening());
    _nativeControlSubscription = _nativePlaybackBridge.controlEvents.listen(
      (event) {
        unawaited(_handleNativePlaybackControlEvent(event));
      },
    );
    _initializePlayer();
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _nativeControlSubscription?.cancel();
    _autoBackgroundRetryTimer?.cancel();
    _autoBackgroundRetryTimer = null;
    unawaited(
      _nativePlaybackBridge.configurePip(
        enabled: false,
        aspectWidth: 16,
        aspectHeight: 9,
        autoEnter: false,
      ),
    );
    unawaited(_nativePlaybackBridge.stopMediaSession());
    unawaited(_disposeCurrentController(resetPlaybackState: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final now = DateTime.now();
      if (now.difference(_lastLifecycleBackgroundHandledAt) >=
          _backgroundLifecycleDebounce) {
        _lastLifecycleBackgroundHandledAt = now;
        unawaited(_handleLifecycleBackgroundTransition(controller));
      }
      return;
    }

    if (state == AppLifecycleState.resumed) {
      unawaited(_handleLifecycleResumed(controller));
    }
  }

  bool _isControllerActive(VideoPlayerController controller) {
    return !_isDisposed &&
        identical(_controller, controller) &&
        controller.value.isInitialized;
  }

  Future<void> _handleLifecycleBackgroundTransition(
    VideoPlayerController lifecycleController,
  ) async {
    if (_isHandlingLifecycleBackgroundTransition ||
        !_isControllerActive(lifecycleController)) {
      return;
    }

    _isHandlingLifecycleBackgroundTransition = true;
    try {
      if (_allowBackgroundContinuation && !lifecycleController.value.isPlaying) {
        await lifecycleController.play();
      }

      if (!_isControllerActive(lifecycleController)) {
        return;
      }

      await _refreshPipAutoEnterForCurrentState(lifecycleController);

      if (_allowBackgroundContinuation &&
          !_isAudioOnly &&
          lifecycleController.value.isPlaying) {
        unawaited(_nativePlaybackBridge.enterPipNow());
      }

      await _syncPlaybackRuntimeState(
        isPlaying: lifecycleController.value.isPlaying,
        force: true,
      );

      if (_allowBackgroundContinuation && !lifecycleController.value.isPlaying) {
        await Future.delayed(_backgroundRecoveryDelay);

        if (!_isControllerActive(lifecycleController) ||
            !_allowBackgroundContinuation ||
            lifecycleController.value.isPlaying) {
          return;
        }

        await lifecycleController.play();
        await _syncPlaybackRuntimeState(
          isPlaying: lifecycleController.value.isPlaying,
          force: true,
        );

        if (!_isAudioOnly && lifecycleController.value.isPlaying) {
          unawaited(_nativePlaybackBridge.enterPipNow());
        }
      }
    } catch (e) {
      debugPrint('Background lifecycle handoff failed: $e');
    } finally {
      _isHandlingLifecycleBackgroundTransition = false;
    }
  }

  Future<void> _handleLifecycleResumed(
    VideoPlayerController lifecycleController,
  ) async {
    if (!_isControllerActive(lifecycleController)) {
      return;
    }

    await _refreshPipAutoEnterForCurrentState(lifecycleController);
    await _syncPlaybackRuntimeState(
      isPlaying: lifecycleController.value.isPlaying,
      force: true,
    );
  }

  Future<void> _initializePlayer() async {
    final playbackSessionId = ++_activePlaybackSessionId;

    setState(() {
      _isInitializing = true;
      _hasError = false;
      _errorText = null;
    });

    await _disposeCurrentController();

    if (_isSessionStale(playbackSessionId)) {
      return;
    }

    _hasAutoBackgroundHandoff = false;
    _autoBackgroundHandoffInProgress = false;
    _autoBackgroundAttemptCount = 0;
    _autoBackgroundRetryTimer?.cancel();
    _autoBackgroundRetryTimer = null;
    _allowBackgroundContinuation = true;
    _didStopMediaSessionAfterCompletion = false;

    try {
      final uri = Uri.parse(widget.media.url);
      final controller = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(
          allowBackgroundPlayback: true,
          mixWithOthers: true,
        ),
      );

      _controller = controller;

      await controller.initialize();
      if (_isSessionStale(playbackSessionId)) {
        await controller.dispose();
        return;
      }

      await controller.setLooping(false);
      await controller.play();
      _allowBackgroundContinuation = true;

      if (_isSessionStale(playbackSessionId)) {
        await controller.dispose();
        return;
      }

      controller.addListener(_onControllerTick);
      await _configurePictureInPicture(controller);
      await _syncPlaybackRuntimeState(
        isPlaying: true,
        force: true,
        expectedSessionId: playbackSessionId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
      });
      unawaited(_triggerAutoBackgroundHandoffIfNeeded());
    } catch (e) {
      if (_isSessionStale(playbackSessionId)) {
        return;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializing = false;
        _hasError = true;
        _errorText = e.toString();
      });
    }
  }

  Future<void> _triggerAutoBackgroundHandoffIfNeeded() async {
    if (_isDisposed ||
        !widget.autoBackgroundStart ||
        _hasAutoBackgroundHandoff ||
        _autoBackgroundHandoffInProgress) {
      return;
    }

    _autoBackgroundHandoffInProgress = true;
    await Future.delayed(const Duration(milliseconds: 900));
    try {
      if (!mounted || _isDisposed || _hasAutoBackgroundHandoff) {
        return;
      }

      final controller = _controller;
      if (controller == null ||
          !controller.value.isInitialized ||
          !controller.value.isPlaying) {
        _scheduleAutoBackgroundRetry();
        return;
      }

      var pipReady = true;
      if (!_isAudioOnly) {
        try {
          pipReady = await _nativePlaybackBridge.enterPipNow();
        } catch (e) {
          pipReady = false;
          debugPrint('Auto PiP entry failed: $e');
        }

        if (pipReady) {
          await Future.delayed(const Duration(milliseconds: 220));
        }
      }

      if (!pipReady) {
        _scheduleAutoBackgroundRetry();
        return;
      }

      try {
        const platform = MethodChannel('com.rajesh.mediatube/app');
        final movedToBackground =
            await platform.invokeMethod<bool>('moveToBackground') ?? false;
        if (movedToBackground) {
          _hasAutoBackgroundHandoff = true;
          _autoBackgroundAttemptCount = 0;
          _autoBackgroundRetryTimer?.cancel();
          _autoBackgroundRetryTimer = null;
        } else {
          _scheduleAutoBackgroundRetry();
        }
      } catch (e) {
        debugPrint('Auto background handoff failed: $e');
        _scheduleAutoBackgroundRetry();
      }
    } finally {
      _autoBackgroundHandoffInProgress = false;
    }
  }

  void _scheduleAutoBackgroundRetry() {
    if (_isDisposed || !widget.autoBackgroundStart || _hasAutoBackgroundHandoff) {
      return;
    }

    if (_autoBackgroundAttemptCount >= _maxAutoBackgroundAttempts) {
      return;
    }

    _autoBackgroundAttemptCount++;
    _autoBackgroundRetryTimer?.cancel();
    _autoBackgroundRetryTimer = Timer(_autoBackgroundRetryDelay, () {
      if (_isDisposed || !mounted) {
        return;
      }
      unawaited(_triggerAutoBackgroundHandoffIfNeeded());
    });
  }

  void _onControllerTick() {
    if (_isDisposed || !mounted) {
      return;
    }
    final controller = _controller;
    if (controller == null) {
      return;
    }

    final value = controller.value;
    final isPlaying = value.isPlaying;

    if (isPlaying) {
      _didStopMediaSessionAfterCompletion = false;
    } else if (!_didStopMediaSessionAfterCompletion &&
        value.duration > Duration.zero &&
        value.position >= value.duration) {
      _didStopMediaSessionAfterCompletion = true;
      unawaited(_nativePlaybackBridge.stopMediaSession());
    }

    final now = DateTime.now();

    if (_lastKnownIsPlaying != isPlaying ||
        now.difference(_lastNativeRuntimeSyncAt) >= _runtimeSyncInterval) {
      unawaited(_syncPlaybackRuntimeState(isPlaying: isPlaying));
    }

    if (now.difference(_lastUiRefreshAt) >= _uiRefreshInterval ||
        value.position >= value.duration) {
      _lastUiRefreshAt = now;
      setState(() {});
    }
  }

  Future<void> _configurePictureInPicture(
    VideoPlayerController controller,
  ) async {
    if (_isAudioOnly) {
      await _configurePipIfNeeded(
        enabled: false,
        aspectWidth: 16,
        aspectHeight: 9,
        autoEnter: false,
      );
      return;
    }

    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final aspectWidth = (aspectRatio * 1000).round();

    await _configurePipIfNeeded(
      enabled: true,
      aspectWidth: aspectWidth <= 0 ? 16 : aspectWidth,
      aspectHeight: 1000,
      autoEnter: true,
    );
  }

  Future<void> _configurePipIfNeeded({
    required bool enabled,
    required int aspectWidth,
    required int aspectHeight,
    required bool autoEnter,
    bool force = false,
  }) async {
    final normalizedWidth = aspectWidth <= 0 ? 16 : aspectWidth;
    final normalizedHeight = aspectHeight <= 0 ? 9 : aspectHeight;

    if (!force &&
        _lastConfiguredPipEnabled == enabled &&
        _lastConfiguredPipAutoEnter == autoEnter &&
        _lastConfiguredPipAspectWidth == normalizedWidth &&
        _lastConfiguredPipAspectHeight == normalizedHeight) {
      return;
    }

    _lastConfiguredPipEnabled = enabled;
    _lastConfiguredPipAutoEnter = autoEnter;
    _lastConfiguredPipAspectWidth = normalizedWidth;
    _lastConfiguredPipAspectHeight = normalizedHeight;

    await _nativePlaybackBridge.configurePip(
      enabled: enabled,
      aspectWidth: normalizedWidth,
      aspectHeight: normalizedHeight,
      autoEnter: autoEnter,
    );
  }

  Future<void> _refreshPipAutoEnterForCurrentState(
    VideoPlayerController controller,
  ) async {
    if (_isAudioOnly) {
      return;
    }

    if (_allowBackgroundContinuation && controller.value.isPlaying) {
      await _configurePictureInPicture(controller);
      return;
    }

    await _configurePipIfNeeded(
      enabled: true,
      aspectWidth: 16,
      aspectHeight: 9,
      autoEnter: false,
    );
  }

  Future<void> _syncPlaybackRuntimeState({
    required bool isPlaying,
    bool force = false,
    int? expectedSessionId,
  }) async {
    if (_isDisposed) {
      return;
    }

    if (expectedSessionId != null && expectedSessionId != _activePlaybackSessionId) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final now = DateTime.now();
    final playbackStateChanged = _lastKnownIsPlaying != isPlaying;
    final isProgressSyncDue =
      now.difference(_lastNativeRuntimeSyncAt) >= _runtimeSyncInterval;

    if (!force && !playbackStateChanged && !isProgressSyncDue) {
      return;
    }

    _lastKnownIsPlaying = isPlaying;
    _lastNativeRuntimeSyncAt = now;

    try {
      await _nativePlaybackBridge.updateMediaSession(
        title: widget.media.title,
        subtitle: widget.media.quality ?? (_isAudioOnly ? 'Audio' : 'Video'),
        duration: controller.value.duration,
        position: controller.value.position,
        isPlaying: isPlaying,
        isVideo: !_isAudioOnly,
        artworkUri: widget.media.thumbnailUrl,
        mimeType: _isAudioOnly ? 'audio/mpeg' : 'video/mp4',
      );
    } catch (e) {
      debugPrint('Failed to update native media session: $e');
    }
  }

  Future<void> _handleNativePlaybackControlEvent(
    NativePlaybackControlEvent event,
  ) async {
    if (_isDisposed) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    switch (event.action) {
      case NativePlaybackControlAction.play:
        _allowBackgroundContinuation = true;
        await controller.play();
        break;
      case NativePlaybackControlAction.pause:
        _allowBackgroundContinuation = false;
        await controller.pause();
        break;
      case NativePlaybackControlAction.toggle:
        if (controller.value.isPlaying) {
          _allowBackgroundContinuation = false;
          await controller.pause();
        } else {
          _allowBackgroundContinuation = true;
          await controller.play();
        }
        break;
      case NativePlaybackControlAction.stop:
        _allowBackgroundContinuation = false;
        await controller.pause();
        await controller.seekTo(Duration.zero);
        _didStopMediaSessionAfterCompletion = true;
        await _nativePlaybackBridge.stopMediaSession();
        if (mounted) {
          setState(() {});
        }
        return;
      case NativePlaybackControlAction.seek:
        final requestedPosition = event.position;
        if (requestedPosition != null) {
          final duration = controller.value.duration;
          final boundedPosition = requestedPosition <= Duration.zero
              ? Duration.zero
              : (requestedPosition >= duration ? duration : requestedPosition);
          await controller.seekTo(boundedPosition);
        }
        break;
    }

    await _refreshPipAutoEnterForCurrentState(controller);

    await _syncPlaybackRuntimeState(
      isPlaying: controller.value.isPlaying,
      force: true,
    );

    if (mounted) {
      setState(() {});
    }
  }

  String _formatDuration(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = value.inHours;
    final m = value.inMinutes.remainder(60);
    final s = value.inSeconds.remainder(60);

    if (h > 0) {
      return '$h:${two(m)}:${two(s)}';
    }
    return '${two(m)}:${two(s)}';
  }

  void _seekRelative(Duration delta) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final current = controller.value.position;
    final target = current + delta;

    final duration = controller.value.duration;
    if (target <= Duration.zero) {
      controller.seekTo(Duration.zero);
      return;
    }

    if (target >= duration) {
      controller.seekTo(duration);
      return;
    }

    controller.seekTo(target);
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isPlaying) {
      _allowBackgroundContinuation = false;
      await controller.pause();
      // Disable PiP auto-enter when paused so minimizing doesn't
      // enter PiP for a paused video.
      if (!_isAudioOnly) {
        unawaited(
          _configurePipIfNeeded(
            enabled: true,
            aspectWidth: 16,
            aspectHeight: 9,
            autoEnter: false,
          ),
        );
      }
    } else {
      _didStopMediaSessionAfterCompletion = false;
      _allowBackgroundContinuation = true;
      await controller.play();
      // Re-enable PiP auto-enter when playing resumes.
      if (!_isAudioOnly) {
        unawaited(_configurePictureInPicture(controller));
      }
    }

    await _syncPlaybackRuntimeState(
      isPlaying: controller.value.isPlaying,
      force: true,
    );

    if (mounted) {
      setState(() {});
    }
  }

  bool _isSessionStale(int playbackSessionId) {
    return _isDisposed || playbackSessionId != _activePlaybackSessionId;
  }

  Future<void> _disposeCurrentController({
    bool resetPlaybackState = true,
  }) async {
    final controller = _controller;
    _controller = null;

    if (controller != null) {
      controller.removeListener(_onControllerTick);
      await controller.dispose();
    }

    if (!resetPlaybackState) {
      return;
    }

    _lastUiRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastNativeRuntimeSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastKnownIsPlaying = null;
    _isHandlingLifecycleBackgroundTransition = false;
    _lastLifecycleBackgroundHandledAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastConfiguredPipEnabled = null;
    _lastConfiguredPipAutoEnter = null;
    _lastConfiguredPipAspectWidth = null;
    _lastConfiguredPipAspectHeight = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Playback'),
        actions: [
          if (!_isAudioOnly && controller != null && controller.value.isInitialized)
            IconButton(
              tooltip: 'Picture in Picture',
              icon: const Icon(Icons.picture_in_picture_alt),
              onPressed: () {
                unawaited(_nativePlaybackBridge.enterPipNow());
              },
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.media.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isAudioOnly
                    ? 'Background music mode enabled. Playback continues when app is backgrounded or screen is off.'
                    : 'Background video mode enabled. Playback continues when app is backgrounded or screen is off.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              Expanded(
                child: _isInitializing
                    ? const Center(child: CircularProgressIndicator())
                    : _hasError
                    ? _buildErrorCard(theme)
                    : _buildPlayerCard(controller!, theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 42),
            const SizedBox(height: 10),
            const Text(
              'Unable to start playback',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _errorText ?? 'Unknown error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _initializePlayer,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerCard(VideoPlayerController controller, ThemeData theme) {
    final value = controller.value;
    final duration = value.duration;
    final position = value.position;
    final maxMs = duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds;
    final currentMs = position.inMilliseconds.clamp(0, maxMs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Expanded(
              child: _isAudioOnly
                  ? Center(
                      child: Icon(
                        Icons.graphic_eq,
                        size: 88,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: value.aspectRatio > 0
                            ? value.aspectRatio
                            : 16 / 9,
                        child: VideoPlayer(controller),
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            Slider(
              value: currentMs.toDouble(),
              min: 0,
              max: maxMs.toDouble(),
              onChanged: (newValue) {
                controller.seekTo(Duration(milliseconds: newValue.toInt()));
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(position)),
                Text(_formatDuration(duration)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => _seekRelative(const Duration(seconds: -10)),
                  icon: const Icon(Icons.replay_10),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _togglePlayPause,
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                  label: Text(value.isPlaying ? 'Pause' : 'Play'),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: () => _seekRelative(const Duration(seconds: 10)),
                  icon: const Icon(Icons.forward_10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
