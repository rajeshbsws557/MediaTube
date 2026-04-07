import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum NativePlaybackControlAction {
  play,
  pause,
  toggle,
  stop,
  seek,
}

class NativePlaybackControlEvent {
  final NativePlaybackControlAction action;
  final Duration? position;

  const NativePlaybackControlEvent({
    required this.action,
    this.position,
  });
}

class AndroidPlaybackBridgeService {
  static final AndroidPlaybackBridgeService _instance =
      AndroidPlaybackBridgeService._internal();

  factory AndroidPlaybackBridgeService() => _instance;

  AndroidPlaybackBridgeService._internal();

  static const MethodChannel _methodChannel =
      MethodChannel('com.rajesh.mediatube/playback_native');
  static const EventChannel _eventChannel =
      EventChannel('com.rajesh.mediatube/playback_native_events');

  final StreamController<NativePlaybackControlEvent> _controlEvents =
      StreamController<NativePlaybackControlEvent>.broadcast();
  final StreamController<bool> _pipModeEvents =
      StreamController<bool>.broadcast();

  StreamSubscription<dynamic>? _nativeEventsSubscription;
  bool _isListening = false;

  String? _lastSessionTitle;
  String? _lastSessionSubtitle;
  int _lastSessionDurationMs = -1;
  int _lastSessionPositionMs = -1;
  bool? _lastSessionIsPlaying;
  bool? _lastSessionIsVideo;
  String? _lastSessionArtworkUri;
  String? _lastSessionMimeType;
  DateTime _lastSessionDispatchAt = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<NativePlaybackControlEvent> get controlEvents => _controlEvents.stream;
  Stream<bool> get pipModeEvents => _pipModeEvents.stream;

  Future<void> ensureListening() async {
    if (!Platform.isAndroid || _isListening) {
      return;
    }

    _nativeEventsSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (_) {},
    );

    _isListening = true;
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) {
      return;
    }

    final payload = event.cast<Object?, Object?>();
    final eventType = payload['event']?.toString();

    if (eventType == 'pipChanged') {
      final inPip = payload['inPip'] == true;
      _pipModeEvents.add(inPip);
      return;
    }

    if (eventType != 'mediaControl') {
      return;
    }

    final rawAction = payload['action']?.toString() ?? '';
    final action = switch (rawAction) {
      'play' => NativePlaybackControlAction.play,
      'pause' => NativePlaybackControlAction.pause,
      'toggle' => NativePlaybackControlAction.toggle,
      'stop' => NativePlaybackControlAction.stop,
      'seek' => NativePlaybackControlAction.seek,
      _ => null,
    };

    if (action == null) {
      return;
    }

    final rawPosition = payload['positionMs'];
    Duration? position;
    if (rawPosition is num) {
      position = Duration(milliseconds: rawPosition.toInt());
    }

    _controlEvents.add(
      NativePlaybackControlEvent(action: action, position: position),
    );
  }

  Future<void> configurePip({
    required bool enabled,
    required int aspectWidth,
    required int aspectHeight,
    bool autoEnter = true,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    await _methodChannel.invokeMethod<void>('configurePip', {
      'enabled': enabled,
      'aspectWidth': aspectWidth,
      'aspectHeight': aspectHeight,
      'autoEnter': autoEnter,
    });
  }

  Future<bool> enterPipNow() async {
    if (!Platform.isAndroid) {
      return false;
    }

    final result = await _methodChannel.invokeMethod<bool>('enterPipNow');
    return result ?? false;
  }

  Future<void> updateMediaSession({
    required String title,
    required String subtitle,
    required Duration duration,
    required Duration position,
    required bool isPlaying,
    required bool isVideo,
    String? artworkUri,
    String mimeType = 'video/mp4',
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    final now = DateTime.now();
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;

    final isLikelyDuplicate =
        _lastSessionTitle == title &&
        _lastSessionSubtitle == subtitle &&
        _lastSessionDurationMs == durationMs &&
        _lastSessionIsPlaying == isPlaying &&
        _lastSessionIsVideo == isVideo &&
        _lastSessionArtworkUri == artworkUri &&
        _lastSessionMimeType == mimeType &&
        (positionMs - _lastSessionPositionMs).abs() < 350 &&
        now.difference(_lastSessionDispatchAt) < const Duration(milliseconds: 700);

    if (isLikelyDuplicate) {
      return;
    }

    _lastSessionTitle = title;
    _lastSessionSubtitle = subtitle;
    _lastSessionDurationMs = durationMs;
    _lastSessionPositionMs = positionMs;
    _lastSessionIsPlaying = isPlaying;
    _lastSessionIsVideo = isVideo;
    _lastSessionArtworkUri = artworkUri;
    _lastSessionMimeType = mimeType;
    _lastSessionDispatchAt = now;

    await _methodChannel.invokeMethod<void>('updateMediaSession', {
      'title': title,
      'subtitle': subtitle,
      'durationMs': durationMs,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
      'isVideo': isVideo,
      'artworkUri': artworkUri,
      'mimeType': mimeType,
    });
  }

  Future<void> stopMediaSession() async {
    if (!Platform.isAndroid) {
      return;
    }

    _lastSessionTitle = null;
    _lastSessionSubtitle = null;
    _lastSessionDurationMs = -1;
    _lastSessionPositionMs = -1;
    _lastSessionIsPlaying = null;
    _lastSessionIsVideo = null;
    _lastSessionArtworkUri = null;
    _lastSessionMimeType = null;
    _lastSessionDispatchAt = DateTime.fromMillisecondsSinceEpoch(0);

    await _methodChannel.invokeMethod<void>('stopMediaSession');
  }

  Future<void> disposeListeners() async {
    if (!_isListening) return;
    await _nativeEventsSubscription?.cancel();
    _nativeEventsSubscription = null;
    _isListening = false;
    await _controlEvents.close();
  }
}
