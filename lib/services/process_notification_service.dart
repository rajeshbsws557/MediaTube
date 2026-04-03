import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _notifications.initialize(initSettings);

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
  }) async {
    await _ensureInitialized();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'App Process Updates',
        channelDescription: 'Media scan and playback process notifications',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
        onlyAlertOnce: true,
        subText: isVideo ? 'Video background mode' : 'Background music mode',
      ),
    );

    await _notifications.show(
      _playbackNotificationId,
      'Background playback active',
      title,
      details,
    );
  }

  Future<void> clearPlaybackStatus() async {
    await _ensureInitialized();
    await _notifications.cancel(_playbackNotificationId);
  }
}
