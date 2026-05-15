import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Centralized notification coordinator for the entire application.
/// Provides a unified API for showing success, error, progress, and info
/// notifications with debouncing and channel management.
class NotificationManager {
  static final NotificationManager _instance = NotificationManager._internal();
  factory NotificationManager() => _instance;
  NotificationManager._internal();

  // ──────────────── Channels ────────────────
  static const String _downloadChannelId = 'mediatube_downloads';
  static const String _playbackChannelId = 'mediatube_playback';
  static const String _mediaDetectionChannelId = 'mediatube_media_scan';
  static const String _appEventsChannelId = 'mediatube_app_events';

  // ──────────────── Notification IDs ────────────────
  static const int downloadProgressBaseId = 80000;
  static const int downloadCompleteBaseId = 81000;
  static const int downloadErrorBaseId = 82000;
  static const int playbackStatusId = 83001;
  static const int mediaScanId = 83002;
  static const int appEventId = 83003;
  static const int clipboardDetectId = 83004;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  final Map<int, DateTime> _lastShownAt = {};

  void Function(String? actionId, String? payload)? onNotificationTap;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        onNotificationTap?.call(response.actionId, response.payload);
      },
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _downloadChannelId,
          'Downloads',
          description: 'Download progress and completion notifications',
          importance: Importance.low,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _playbackChannelId,
          'Playback',
          description: 'Background playback status',
          importance: Importance.high,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _mediaDetectionChannelId,
          'Media Detection',
          description: 'Media scan and detection results',
          importance: Importance.defaultImportance,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _appEventsChannelId,
          'App Events',
          description: 'General app notifications',
          importance: Importance.defaultImportance,
        ),
      );
    }

    _initialized = true;
  }

  /// Debounce guard — returns true if enough time has passed.
  bool _shouldShow(int id, Duration minInterval) {
    final now = DateTime.now();
    final lastShown = _lastShownAt[id];
    if (lastShown != null && now.difference(lastShown) < minInterval) {
      return false;
    }
    _lastShownAt[id] = now;
    return true;
  }

  // ═══════════════════════════════════════════════════════════════
  //  DOWNLOAD NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Show download progress notification with pause/cancel actions.
  Future<void> showDownloadProgress({
    required String taskId,
    required String title,
    required double progress,
    int? downloadedBytes,
    int? totalBytes,
  }) async {
    await _ensureInitialized();

    final id = downloadProgressBaseId + taskId.hashCode.abs() % 999;
    if (!_shouldShow(id, const Duration(milliseconds: 800))) return;

    final percent = (progress * 100).toInt().clamp(0, 100);
    final body = totalBytes != null && totalBytes > 0
        ? '${_formatBytes(downloadedBytes ?? 0)} / ${_formatBytes(totalBytes)} ($percent%)'
        : '$percent% complete';

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _downloadChannelId,
        'Downloads',
        channelDescription: 'Download progress and completion notifications',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        onlyAlertOnce: true,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        category: AndroidNotificationCategory.progress,
        actions: <AndroidNotificationAction>[
          const AndroidNotificationAction(
            'pause_download',
            'Pause',
            showsUserInterface: false,
          ),
          const AndroidNotificationAction(
            'cancel_download',
            'Cancel',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
    );

    await _plugin.show(id, 'Downloading $title', body, details,
        payload: taskId);
  }

  /// Show download complete notification with "Open" action.
  Future<void> showDownloadComplete({
    required String taskId,
    required String title,
    String? filePath,
  }) async {
    await _ensureInitialized();

    // Cancel any lingering progress notification
    final progressId = downloadProgressBaseId + taskId.hashCode.abs() % 999;
    await _plugin.cancel(progressId);

    final id = downloadCompleteBaseId + taskId.hashCode.abs() % 999;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _downloadChannelId,
        'Downloads',
        channelDescription: 'Download progress and completion notifications',
        importance: Importance.high,
        priority: Priority.high,
        onlyAlertOnce: true,
        actions: filePath != null
            ? <AndroidNotificationAction>[
                const AndroidNotificationAction(
                  'open_file',
                  'Open',
                  showsUserInterface: true,
                ),
              ]
            : null,
      ),
    );

    await _plugin.show(id, 'Download complete', title, details,
        payload: filePath ?? taskId);
  }

  /// Show download error notification with "Retry" action.
  Future<void> showDownloadError({
    required String taskId,
    required String title,
    required String error,
  }) async {
    await _ensureInitialized();

    // Cancel progress notification
    final progressId = downloadProgressBaseId + taskId.hashCode.abs() % 999;
    await _plugin.cancel(progressId);

    final id = downloadErrorBaseId + taskId.hashCode.abs() % 999;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _downloadChannelId,
        'Downloads',
        channelDescription: 'Download progress and completion notifications',
        importance: Importance.high,
        priority: Priority.high,
        actions: <AndroidNotificationAction>[
          const AndroidNotificationAction(
            'retry_download',
            'Retry',
            showsUserInterface: true,
          ),
        ],
      ),
    );

    await _plugin.show(id, 'Download failed: $title', error, details,
        payload: taskId);
  }

  /// Cancel download progress notification.
  Future<void> cancelDownloadNotification(String taskId) async {
    await _ensureInitialized();
    final id = downloadProgressBaseId + taskId.hashCode.abs() % 999;
    await _plugin.cancel(id);
  }

  // ═══════════════════════════════════════════════════════════════
  //  MEDIA SCAN NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════

  Future<void> showMediaScanStarted({required String hostLabel}) async {
    await _ensureInitialized();
    if (!_shouldShow(mediaScanId, const Duration(seconds: 3))) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _mediaDetectionChannelId,
        'Media Detection',
        channelDescription: 'Media scan and detection results',
        importance: Importance.low,
        priority: Priority.low,
        onlyAlertOnce: true,
      ),
    );

    await _plugin.show(
      mediaScanId,
      'Scanning media',
      'Checking $hostLabel for downloadable streams',
      details,
    );
  }

  Future<void> showMediaScanResult({required int count}) async {
    await _ensureInitialized();
    if (!_shouldShow(mediaScanId, const Duration(seconds: 2))) return;

    final title = count > 0 ? 'Media found' : 'No media found';
    final body = count > 0
        ? '$count downloadable stream(s) detected'
        : 'Play the video first, then scan again';

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _mediaDetectionChannelId,
        'Media Detection',
        channelDescription: 'Media scan and detection results',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        onlyAlertOnce: true,
      ),
    );

    await _plugin.show(mediaScanId, title, body, details);
  }

  // ═══════════════════════════════════════════════════════════════
  //  APP EVENT NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Generic success notification.
  Future<void> showSuccess({
    required String title,
    String? body,
    String? payload,
  }) async {
    await _ensureInitialized();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _appEventsChannelId,
        'App Events',
        channelDescription: 'General app notifications',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );

    await _plugin.show(appEventId, title, body, details, payload: payload);
  }

  /// Generic error notification.
  Future<void> showError({
    required String title,
    String? body,
  }) async {
    await _ensureInitialized();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _appEventsChannelId,
        'App Events',
        channelDescription: 'General app notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    await _plugin.show(appEventId, title, body, details);
  }

  /// Show clipboard link detected notification.
  Future<void> showClipboardLinkDetected({required String url}) async {
    await _ensureInitialized();
    if (!_shouldShow(clipboardDetectId, const Duration(seconds: 5))) return;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _appEventsChannelId,
        'App Events',
        channelDescription: 'General app notifications',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        actions: <AndroidNotificationAction>[
          const AndroidNotificationAction(
            'load_clipboard_url',
            'Open',
            showsUserInterface: true,
          ),
        ],
      ),
    );

    await _plugin.show(
      clipboardDetectId,
      'Media link detected',
      url,
      details,
      payload: url,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  UTILITIES
  // ═══════════════════════════════════════════════════════════════

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  Future<void> cancelAll() async {
    await _ensureInitialized();
    await _plugin.cancelAll();
    _lastShownAt.clear();
  }
}
