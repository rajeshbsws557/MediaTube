import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum PlaybackNotificationAction {
  togglePlayPause,
  stopPlayback,
  openApp,
}

/// Lightweight app-process notifications for media scan and playback state.
class ProcessNotificationService {
  static final ProcessNotificationService _instance =
      ProcessNotificationService._internal();

  factory ProcessNotificationService() => _instance;

  ProcessNotificationService._internal();

  static const String _channelId = 'mediatube_process';
  static const int _scanNotificationId = 71001;
  static const int _playbackNotificationId = 71002;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  DateTime? _lastScanStartedAt;
  DateTime? _lastScanResultAt;
  DateTime? _lastPlaybackStatusAt;
  String? _lastPlaybackTitle;
  bool? _lastPlaybackIsPlaying;
  void Function(PlaybackNotificationAction action)? _playbackActionHandler;

  void setPlaybackActionHandler(
    void Function(PlaybackNotificationAction action)? handler,
  ) {
    _playbackActionHandler = handler;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final actionId = response.actionId;

        if (actionId == 'toggle_playback') {
          _playbackActionHandler?.call(
            PlaybackNotificationAction.togglePlayPause,
          );
          return;
        }

        if (actionId == 'stop_playback') {
          _playbackActionHandler?.call(PlaybackNotificationAction.stopPlayback);
          return;
        }

        _playbackActionHandler?.call(PlaybackNotificationAction.openApp);
      },
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      'App Process Updates',
      description: 'Media scan and playback process notifications',
      importance: Importance.defaultImportance,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  Future<void> showMediaScanStarted({required String hostLabel}) async {
    await _ensureInitialized();

    final now = DateTime.now();
    if (_lastScanStartedAt != null &&
        now.difference(_lastScanStartedAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastScanStartedAt = now;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'App Process Updates',
        channelDescription: 'Media scan and playback process notifications',
        importance: Importance.low,
        priority: Priority.low,
        onlyAlertOnce: true,
      ),
    );

    await _notifications.show(
      _scanNotificationId,
      'Scanning media links',
      'Checking $hostLabel for downloadable streams',
      details,
    );
  }

  Future<void> showMediaScanResult({required int count}) async {
    await _ensureInitialized();

    final now = DateTime.now();
    if (_lastScanResultAt != null &&
        now.difference(_lastScanResultAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastScanResultAt = now;

    final title = count > 0 ? 'Media found' : 'No media found';
    final body = count > 0
        ? '$count downloadable stream(s) detected'
        : 'Play the video once, then scan again';

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'App Process Updates',
        channelDescription: 'Media scan and playback process notifications',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        onlyAlertOnce: true,
      ),
    );

    await _notifications.show(_scanNotificationId, title, body, details);
  }

  Future<void> showMediaScanError(String message) async {
    await _ensureInitialized();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'App Process Updates',
        channelDescription: 'Media scan and playback process notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    await _notifications.show(
      _scanNotificationId,
      'Media scan failed',
      message,
      details,
    );
  }

  Future<void> showPlaybackStatus({
    required String title,
    required bool isVideo,
    required bool isPlaying,
  }) async {
    await _ensureInitialized();

    final now = DateTime.now();
    final changedState =
        _lastPlaybackTitle != title || _lastPlaybackIsPlaying != isPlaying;
    if (!changedState &&
        _lastPlaybackStatusAt != null &&
        now.difference(_lastPlaybackStatusAt!) < const Duration(seconds: 1)) {
      return;
    }

    _lastPlaybackStatusAt = now;
    _lastPlaybackTitle = title;
    _lastPlaybackIsPlaying = isPlaying;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'App Process Updates',
        channelDescription: 'Media scan and playback process notifications',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: false, // Ensure that user can swipe to clear it if it gets stuck
        onlyAlertOnce: true,
        subText: isVideo ? 'Video background mode' : 'Background music mode',
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'toggle_playback',
            isPlaying ? 'Pause' : 'Play',
            showsUserInterface: false,
          ),
          AndroidNotificationAction(
            'stop_playback',
            'Stop',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
    );

    await _notifications.show(
      _playbackNotificationId,
      isPlaying ? 'Background playback active' : 'Playback paused',
      title,
      details,
    );
  }

  Future<void> clearPlaybackStatus() async {
    await _ensureInitialized();
    _lastPlaybackStatusAt = null;
    _lastPlaybackTitle = null;
    _lastPlaybackIsPlaying = null;
    await _notifications.cancel(_playbackNotificationId);
  }
}
