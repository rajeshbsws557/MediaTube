import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service to manage download notifications with detailed progress
class BackgroundDownloadService {
  static final BackgroundDownloadService _instance = BackgroundDownloadService._internal();
  factory BackgroundDownloadService() => _instance;
  BackgroundDownloadService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  /// Format bytes to human readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
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
    
    await _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

    _isInitialized = true;
  }

  /// Start the service (now just ensures initialization)
  Future<void> startService() async {
    if (!_isInitialized) await initialize();
  }

  /// Stop the service (now a no-op)
  Future<void> stopService() async {
    // No-op - we're not using background service anymore
  }

  /// Update download progress notification with detailed info
  Future<void> updateProgressDetailed({
    required String title,
    required double progress,
    required int downloadedBytes,
    required int totalBytes,
    required bool isMerging,
    required int downloadId,
  }) async {
    if (!_isInitialized) await initialize();
    
    final progressPercent = (progress * 100).toInt();
    
    String statusText;
    if (isMerging) {
      statusText = 'Merging: $progressPercent%';
    } else if (totalBytes > 0) {
      statusText = '${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)} ($progressPercent%)';
    } else {
      statusText = '${_formatBytes(downloadedBytes)} - $progressPercent%';
    }
    
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
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
      subText: isMerging ? 'Merging video & audio' : 'Downloading',
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      isMerging ? 'Merging' : 'Downloading',
      '$title\n$statusText',
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
    
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
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
    
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
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
