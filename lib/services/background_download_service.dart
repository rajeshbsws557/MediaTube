import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Service to manage download notifications with detailed progress
/// Also handles foreground service for background downloads
class BackgroundDownloadService {
  static final BackgroundDownloadService _instance =
      BackgroundDownloadService._internal();
  factory BackgroundDownloadService() => _instance;
  BackgroundDownloadService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _foregroundServiceRunning = false;

  /// Format bytes to human readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize notifications
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );

    await _notifications.initialize(initSettings);

    // Create notification channel
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'mediatube_downloads',
      'Downloads',
      description: 'Download progress notifications',
      importance: Importance.low,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    // Initialize foreground task
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mediatube_foreground',
        channelName: 'MediaTube Downloads',
        channelDescription: 'Keeps downloads running in background',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// Start the foreground service - keeps app alive for downloads
  Future<void> startService() async {
    if (!_isInitialized) await initialize();

    if (!_foregroundServiceRunning) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'MediaTube',
        notificationText: 'Downloading in background...',
        notificationIcon: null,
      );
      _foregroundServiceRunning = true;
    }
  }

  /// Stop the foreground service
  Future<void> stopService() async {
    if (_foregroundServiceRunning) {
      await FlutterForegroundTask.stopService();
      _foregroundServiceRunning = false;
    }
  }

  /// Update download progress notification with detailed info including speed and ETA
  Future<void> updateProgressDetailed({
    required String title,
    required double progress,
    required int downloadedBytes,
    required int totalBytes,
    required bool isMerging,
    required int downloadId,
    int? speedBytesPerSec,
  }) async {
    if (!_isInitialized) await initialize();

    final progressPercent = (progress * 100).toInt();

    // Format speed
    String speedText = '';
    if (speedBytesPerSec != null && speedBytesPerSec > 0) {
      speedText = ' • ${_formatBytes(speedBytesPerSec)}/s';
    }

    // Calculate ETA
    String etaText = '';
    if (speedBytesPerSec != null && speedBytesPerSec > 0 && totalBytes > 0) {
      final remainingBytes = totalBytes - downloadedBytes;
      final etaSeconds = remainingBytes ~/ speedBytesPerSec;
      if (etaSeconds < 60) {
        etaText = ' • ${etaSeconds}s left';
      } else if (etaSeconds < 3600) {
        etaText = ' • ${etaSeconds ~/ 60}m ${etaSeconds % 60}s left';
      } else {
        etaText =
            ' • ${etaSeconds ~/ 3600}h ${(etaSeconds % 3600) ~/ 60}m left';
      }
    }

    String statusText;
    if (isMerging) {
      statusText = 'Merging: $progressPercent%';
    } else if (totalBytes > 0) {
      statusText =
          '${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)}$speedText$etaText';
    } else {
      statusText = '${_formatBytes(downloadedBytes)}$speedText';
    }

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: progressPercent,
          onlyAlertOnce: true,
          channelShowBadge: false,
          subText: '$progressPercent%',
        );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      title, // Use actual title instead of generic "Downloading"
      statusText,
      notificationDetails,
    );
  }

  /// Legacy update method - redirects to detailed
  Future<void> updateProgress({
    required String title,
    required double progress,
    required int downloadId,
  }) async {
    await updateProgressDetailed(
      title: title,
      progress: progress,
      downloadedBytes: 0,
      totalBytes: 0,
      isMerging: false,
      downloadId: downloadId,
    );
  }

  /// Show download complete notification
  Future<void> showCompleteNotification({
    required String title,
    required int downloadId,
  }) async {
    if (!_isInitialized) await initialize();

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.high,
          priority: Priority.high,
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      'Download Complete',
      title,
      notificationDetails,
    );
  }

  /// Show download failed notification
  Future<void> showFailedNotification({
    required String title,
    required String error,
    required int downloadId,
  }) async {
    if (!_isInitialized) await initialize();

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.high,
          priority: Priority.high,
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      'Download Failed',
      '$title: $error',
      notificationDetails,
    );
  }

  /// Cancel a notification
  Future<void> cancelNotification(int downloadId) async {
    await _notifications.cancel(downloadId);
  }
}
