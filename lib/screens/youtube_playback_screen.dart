import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../services/services.dart';

class YoutubePlaybackScreen extends StatefulWidget {
  final DetectedMedia media;

  const YoutubePlaybackScreen({
    super.key,
    required this.media,
  });

  @override
  State<YoutubePlaybackScreen> createState() => _YoutubePlaybackScreenState();
}

class _YoutubePlaybackScreenState extends State<YoutubePlaybackScreen>
    with WidgetsBindingObserver {
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
    WidgetsBinding.instance.removeObserver(this);
    _nativeControlSubscription?.cancel();
    unawaited(
      _nativePlaybackBridge.configurePip(
        enabled: false,
        aspectWidth: 16,
        aspectHeight: 9,
        autoEnter: false,
      ),
    );
    unawaited(_nativePlaybackBridge.stopMediaSession());
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        unawaited(
          _syncPlaybackRuntimeState(
            isPlaying: controller.value.isPlaying,
            force: true,
          ),
        );
      }
    }
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isInitializing = true;
      _hasError = false;
      _errorText = null;
    });

    try {
      final uri = Uri.parse(widget.media.url);
      final controller = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(
          allowBackgroundPlayback: true,
          mixWithOthers: true,
        ),
      );

      await controller.initialize();
      await controller.setLooping(false);
      await controller.play();

      controller.addListener(_onControllerTick);

      _controller = controller;
      await _configurePictureInPicture(controller);
      await _syncPlaybackRuntimeState(isPlaying: true, force: true);

      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
      });
    } catch (e) {
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

  void _onControllerTick() {
    if (!mounted) {
      return;
    }
    final controller = _controller;
    if (controller == null) {
      return;
    }

    final isPlaying = controller.value.isPlaying;
    final now = DateTime.now();
    final shouldSyncNative =
        _lastKnownIsPlaying != isPlaying ||
        now.difference(_lastNativeRuntimeSyncAt) >=
            const Duration(milliseconds: 900);

    if (shouldSyncNative) {
      unawaited(_syncPlaybackRuntimeState(isPlaying: isPlaying));
    }

    final shouldRefreshUi =
        now.difference(_lastUiRefreshAt) >= const Duration(milliseconds: 220) ||
        controller.value.position >= controller.value.duration;

    if (shouldRefreshUi) {
      _lastUiRefreshAt = now;
      setState(() {});
    }
  }

  Future<void> _configurePictureInPicture(
    VideoPlayerController controller,
  ) async {
    if (_isAudioOnly) {
      await _nativePlaybackBridge.configurePip(
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

    await _nativePlaybackBridge.configurePip(
      enabled: true,
      aspectWidth: aspectWidth <= 0 ? 16 : aspectWidth,
      aspectHeight: 1000,
      autoEnter: true,
    );
  }

  Future<void> _syncPlaybackRuntimeState({
    required bool isPlaying,
    bool force = false,
  }) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final now = DateTime.now();
    final playbackStateChanged = _lastKnownIsPlaying != isPlaying;
    final isProgressSyncDue =
        now.difference(_lastNativeRuntimeSyncAt) >=
        const Duration(milliseconds: 900);

    if (!force && !playbackStateChanged && !isProgressSyncDue) {
      return;
    }

    _lastKnownIsPlaying = isPlaying;
    _lastNativeRuntimeSyncAt = now;

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
  }

  Future<void> _handleNativePlaybackControlEvent(
    NativePlaybackControlEvent event,
  ) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    switch (event.action) {
      case NativePlaybackControlAction.play:
        await controller.play();
        break;
      case NativePlaybackControlAction.pause:
        await controller.pause();
        break;
      case NativePlaybackControlAction.toggle:
        if (controller.value.isPlaying) {
          await controller.pause();
        } else {
          await controller.play();
        }
        break;
      case NativePlaybackControlAction.stop:
        await controller.pause();
        await controller.seekTo(Duration.zero);
        break;
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
      await controller.pause();
    } else {
      await controller.play();
    }

    await _syncPlaybackRuntimeState(
      isPlaying: controller.value.isPlaying,
      force: true,
    );

    if (mounted) {
      setState(() {});
    }
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
      body: Padding(
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
