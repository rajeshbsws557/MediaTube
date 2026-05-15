import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../main.dart';

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
  bool _downloadSessionRequested = false;
  bool _playbackSessionRequested = false;

  /// Format bytes to human readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
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

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final SendPort? sendPort = IsolateNameServer.lookupPortByName(
          'download_actions_port',
        );
        if (sendPort != null) {
          if (response.actionId != null) {
            if (response.payload != null) {
              sendPort.send('${response.actionId}_${response.payload}');
            } else {
              sendPort.send(response.actionId);
            }
          } else if (response.payload != null) {
            sendPort.send('open_${response.payload}');
          }
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

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

  Future<void> _showOrUpdateForegroundService({
    required String title,
    required String text,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (!_foregroundServiceRunning) {
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        notificationIcon: null,
      );
      _foregroundServiceRunning = true;
      return;
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  Future<void> _syncForegroundServiceState() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_downloadSessionRequested) {
      await _showOrUpdateForegroundService(
        title: 'MediaTube',
        text: 'Downloading in background...',
      );
      return;
    }

    if (_playbackSessionRequested) {
      await _showOrUpdateForegroundService(
        title: 'MediaTube Playback',
        text: 'Playing in background...',
      );
      return;
    }

    if (_foregroundServiceRunning) {
      await FlutterForegroundTask.stopService();
      _foregroundServiceRunning = false;
    }
  }

  /// Start the foreground service - keeps app alive for downloads.
  Future<void> startService() async {
    _downloadSessionRequested = true;
    await _syncForegroundServiceState();
  }

  /// Stop the foreground service for downloads.
  /// Playback can keep the service alive if active.
  Future<void> stopService() async {
    _downloadSessionRequested = false;
    await _syncForegroundServiceState();
  }

  /// Start foreground service protection for media playback.
  Future<void> startPlaybackService({
    required String title,
    required bool isVideo,
  }) async {
    _playbackSessionRequested = true;
    await _showOrUpdateForegroundService(
      title: isVideo ? 'Video playback active' : 'Background music active',
      text: title,
    );
  }

  /// Stop foreground service protection for playback.
  /// Downloads can keep the service alive if active.
  Future<void> stopPlaybackService() async {
    _playbackSessionRequested = false;
    await _syncForegroundServiceState();
  }

  /// Update download progress notification with detailed info including speed and ETA
  Future<void> updateProgressDetailed({
    required String title,
    required double progress,
    required int downloadedBytes,
    required int totalBytes,
    required bool isMerging,
    required int downloadId,
    required String taskId,
    bool isPaused = false,
    int? speedBytesPerSec,
  }) async {
    if (!_isInitialized) await initialize();

    final progressPercent = (progress * 100).toInt();

    // Format speed
    String speedText = '';
    if (speedBytesPerSec != null && speedBytesPerSec > 0 && !isPaused) {
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
    if (isPaused) {
      statusText =
          'Paused - ${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)}';
    } else if (isMerging) {
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
          ongoing: !isPaused,
          showProgress: !isPaused,
          maxProgress: 100,
          progress: progressPercent,
          onlyAlertOnce: true,
          channelShowBadge: false,
          subText: isPaused ? 'Paused' : '$progressPercent%',
          groupKey: 'mediatube_downloads_group',
          actions: isPaused
              ? <AndroidNotificationAction>[
                  AndroidNotificationAction(
                    'resume',
                    'Resume',
                    showsUserInterface: false,
                  ),
                  AndroidNotificationAction(
                    'cancel',
                    'Cancel',
                    showsUserInterface: false,
                    cancelNotification: true,
                  ),
                ]
              : <AndroidNotificationAction>[
                  AndroidNotificationAction(
                    'pause',
                    'Pause',
                    showsUserInterface: false,
                  ),
                  AndroidNotificationAction(
                    'cancel',
                    'Cancel',
                    showsUserInterface: false,
                    cancelNotification: true,
                  ),
                ],
        );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      title, // Use actual title instead of generic "Downloading"
      statusText,
      notificationDetails,
      payload: taskId,
    );

    // Show summary notification for grouping
    await _showGroupSummary();
  }

  Future<void> _showGroupSummary() async {
    const AndroidNotificationDetails summaryDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.low,
          priority: Priority.low,
          groupKey: 'mediatube_downloads_group',
          setAsGroupSummary: true,
          onlyAlertOnce: true,
        );

    await _notifications.show(
      99999, // Unique ID for summary
      'MediaTube Downloads',
      'Active downloads',
      const NotificationDetails(android: summaryDetails),
    );
  }

  /// Legacy update method - redirects to detailed
  Future<void> updateProgress({
    required String title,
    required double progress,
    required int downloadId,
    required String taskId,
  }) async {
    await updateProgressDetailed(
      title: title,
      progress: progress,
      downloadedBytes: 0,
      totalBytes: 0,
      isMerging: false,
      downloadId: downloadId,
      taskId: taskId,
    );
  }

  /// Show download complete notification
  Future<void> showCompleteNotification({
    required String title,
    required int downloadId,
    required String taskId,
    required String savePath,
  }) async {
    if (!_isInitialized) await initialize();

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.high,
          priority: Priority.high,
          groupKey: 'mediatube_downloads_group',
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction('open', 'Open', showsUserInterface: true),
            AndroidNotificationAction(
              'share',
              'Share',
              showsUserInterface: true,
            ),
          ],
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      'Download Complete',
      title,
      notificationDetails,
      payload: savePath, // Store path so tapping the notification opens it
    );
    await _showGroupSummary();
  }

  /// Show download failed notification
  Future<void> showFailedNotification({
    required String title,
    required String error,
    required int downloadId,
    required String taskId,
  }) async {
    if (!_isInitialized) await initialize();

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'mediatube_downloads',
          'Downloads',
          channelDescription: 'Download notifications',
          importance: Importance.high,
          priority: Priority.high,
          groupKey: 'mediatube_downloads_group',
          color: Color(0xFFE53935), // Material Red 600
          colorized: true,
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(
              'retry',
              'Retry',
              showsUserInterface: false,
            ),
            AndroidNotificationAction(
              'dismiss',
              'Dismiss',
              showsUserInterface: false,
              cancelNotification: true,
            ),
          ],
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      downloadId,
      'Download Failed',
      '$title: $error',
      notificationDetails,
      payload: taskId,
    );
    await _showGroupSummary();
  }

  /// Cancel a notification
  Future<void> cancelNotification(int downloadId) async {
    await _notifications.cancel(downloadId);
  }
}
