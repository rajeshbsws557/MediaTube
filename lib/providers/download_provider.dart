import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../main.dart'; // Import to access scaffoldMessengerKey

/// Provider for managing downloads with pause/resume support
/// Heavily optimized for smooth UI - minimal rebuilds during downloads
class DownloadProvider extends ChangeNotifier {
  final DownloadService _downloadService = DownloadService();
  final BackgroundDownloadService _backgroundService =
      BackgroundDownloadService();
  final DownloadHistoryService _historyService = DownloadHistoryService();

  final List<DownloadTask> _downloads = [];
  List<DownloadTask> _historyDownloads = []; // Persisted history
  final Map<String, DetectedMedia> _mediaMap =
      {}; // Store media for retry/resume
  int _notificationId = 0;
  bool _historyLoaded = false;
  final ReceivePort _actionPort = ReceivePort();

  // Throttling - reduced frequency for smoother UI (was 100ms)
  Timer? _updateThrottleTimer;
  bool _pendingNotify = false;
  static const _updateThrottleDuration = Duration(milliseconds: 250);

  // Per-download progress notifiers for granular UI updates without full rebuilds
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};

  // Track last progress values to avoid unnecessary updates
  final Map<String, double> _lastProgressValues = {};

  // Speed tracking for notifications
  final Map<String, int> _lastBytesValues = {};
  final Map<String, DateTime> _lastTimeValues = {};
  final Map<String, DateTime> _lastNotificationTimes = {};
  final Map<String, DateTime> _lastHistorySnapshotTimes = {};

  // Limit concurrent downloads - 2 max to prevent bandwidth/thread saturation on mobile
  static const int _maxConcurrentDownloads = 2;
  static const String _interruptedStatusMessage = 'Interrupted - app closed';
  static const String _recoveredStatusMessage = 'Recovered after app restart';

  List<DownloadTask> get downloads => List.unmodifiable(_downloads);
  List<DownloadTask> get activeDownloads => _downloads
      .where(
        (d) =>
            d.status == DownloadStatus.downloading ||
            d.status == DownloadStatus.merging ||
            d.status == DownloadStatus.pending,
      )
      .toList();
  List<DownloadTask> get pausedDownloads =>
      _downloads.where((d) => d.status == DownloadStatus.paused).toList();
  List<DownloadTask> get completedDownloads =>
      _downloads.where((d) => d.status == DownloadStatus.completed).toList();

  /// All downloads including persisted history
  List<DownloadTask> get allDownloadsHistory {
    // Combine current downloads with history (avoiding duplicates)
    final currentIds = _downloads.map((d) => d.id).toSet();
    final historyOnly = _historyDownloads.where(
      (h) => !currentIds.contains(h.id),
    );
    return [..._downloads, ...historyOnly];
  }

  bool get hasActiveDownloads => activeDownloads.isNotEmpty;
  bool get hasPausedDownloads => pausedDownloads.isNotEmpty;

  /// Get progress notifier for a specific download (for granular UI updates)
  ValueNotifier<double>? getProgressNotifier(String taskId) =>
      _progressNotifiers[taskId];

  /// Heavily throttled notify - batches updates to minimize UI rebuilds
  void _throttledNotify() {
    _pendingNotify = true;

    if (_updateThrottleTimer?.isActive ?? false) {
      return; // Timer already running, will pick up pending notify
    }

    _updateThrottleTimer = Timer(_updateThrottleDuration, () {
      if (_pendingNotify) {
        _pendingNotify = false;
        notifyListeners();
      }
    });
  }

  /// Force immediate notify (for important state changes like complete/error)
  void _immediateNotify() {
    _updateThrottleTimer?.cancel();
    _pendingNotify = false;
    notifyListeners();
  }

  DownloadProvider() {
    _initBackgroundService();
    _loadHistory();
  }

  Future<void> _initBackgroundService() async {
    await _backgroundService.initialize();

    IsolateNameServer.removePortNameMapping('download_actions_port');
    IsolateNameServer.registerPortWithName(
      _actionPort.sendPort,
      'download_actions_port',
    );
    _actionPort.listen((message) {
      if (message is String) {
        if (message.startsWith('pause_')) {
          pauseDownload(message.substring(6));
        } else if (message.startsWith('resume_')) {
          resumeDownload(message.substring(7));
        } else if (message.startsWith('cancel_')) {
          cancelDownload(message.substring(7));
          removeDownload(message.substring(7));
        } else if (message.startsWith('retry_')) {
          retryDownload(message.substring(6));
        } else if (message.startsWith('open_')) {
          OpenFilex.open(message.substring(5));
        } else if (message.startsWith('share_')) {
          SharePlus.instance.share(
            ShareParams(files: [XFile(message.substring(6))]),
          );
        }
      }
    });
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyDownloads = await _historyService.getHistory();
    final savedMedia = await _historyService.getSavedMediaMap();
    _mediaMap.addAll(savedMedia);
    _historyLoaded = true;

    _restoreInterruptedDownloads();
    _immediateNotify();
  }

  void _restoreInterruptedDownloads() {
    final recoverable = _historyDownloads.where((task) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.pending ||
          task.status == DownloadStatus.merging) {
        return true;
      }

      return task.status == DownloadStatus.paused &&
          task.statusMessage == _interruptedStatusMessage;
    }).toList();

    if (recoverable.isEmpty) {
      return;
    }

    for (final task in recoverable) {
      if (_downloads.any((d) => d.id == task.id)) continue;

      final recoveredTask = task.copyWith(
        status: DownloadStatus.paused,
        statusMessage: _recoveredStatusMessage,
      );
      _downloads.add(recoveredTask);
      _progressNotifiers[recoveredTask.id] = ValueNotifier<double>(
        recoveredTask.progress,
      );
      _lastProgressValues[recoveredTask.id] = recoveredTask.progress;
    }

    unawaited(_autoResumeRecoveredDownloads());
  }

  Future<void> _autoResumeRecoveredDownloads() async {
    await Future.delayed(const Duration(milliseconds: 400));

    var resumedCount = 0;
    final recoveredIds = _downloads
        .where((task) => task.statusMessage == _recoveredStatusMessage)
        .map((task) => task.id)
        .toList();

    for (final taskId in recoveredIds) {
      if (resumedCount >= _maxConcurrentDownloads) {
        break;
      }

      if (_mediaMap[taskId] == null) {
        continue;
      }

      await resumeDownload(taskId);
      resumedCount++;
    }
  }

  /// Save all active/pending downloads to history (called on app pause/terminate)
  /// This ensures no download is lost even if the app is killed by the OS.
  /// Does NOT change the status of actively downloading tasks — the foreground
  /// service keeps them running. Only creates history snapshots for crash recovery.
  Future<void> saveActiveDownloadsToHistory() async {
    for (final download in _downloads) {
      if (download.status == DownloadStatus.downloading ||
          download.status == DownloadStatus.pending ||
          download.status == DownloadStatus.merging) {
        // Save a SNAPSHOT to history for crash recovery, but do NOT alter the
        // live task's status — the download is still running via the foreground
        // service. If the OS actually kills the process, on next launch the
        // history entry will show the last known state so the user can retry.
        final snapshot = download.copyWith(
          status: DownloadStatus.paused,
          statusMessage: _interruptedStatusMessage,
        );
        await _saveToHistory(snapshot);
      } else if (download.status == DownloadStatus.paused ||
          download.status == DownloadStatus.completed ||
          download.status == DownloadStatus.failed) {
        // Ensure all non-cancelled downloads are persisted
        await _saveToHistory(download);
      }
    }
  }

  Future<void> _saveToHistory(
    DownloadTask task, {
    bool refreshHistory = true,
  }) async {
    await _historyService.saveDownload(task);
    final media = _mediaMap[task.id];
    if (media != null) {
      await _historyService.saveMediaForTask(task.id, media);
    }
    if (refreshHistory) {
      // Refresh history when needed for UI-visible state transitions.
      _historyDownloads = await _historyService.getHistory();
    }
  }

  /// Start downloading a media file with concurrent download limiting
  Future<void> startDownload(DetectedMedia media) async {
    try {
      final task = await _downloadService.createDownloadTask(media);
      final notificationId = _notificationId++;
      _downloads.insert(0, task);
      _mediaMap[task.id] = media; // Store media for retry/resume
      _progressNotifiers[task.id] = ValueNotifier<double>(
        0.0,
      ); // Create progress notifier

      await _historyService.saveMediaForTask(task.id, media);
      await _saveToHistory(task);

      _immediateNotify(); // Immediate update when new download added

      // Check concurrent download limit
      final currentlyDownloading = _downloads
          .where(
            (d) =>
                d.status == DownloadStatus.downloading ||
                d.status == DownloadStatus.merging,
          )
          .length;

      if (currentlyDownloading >= _maxConcurrentDownloads) {
        // Queue this download - it will stay in pending state
        task.status = DownloadStatus.pending;
        task.statusMessage = 'Queued...';
        await _saveToHistory(task);
        notifyListeners();

        // Just return, do NOT wait.
        // _startNextQueuedDownload will pick this up when a slot opens.
        return;
      }

      // Start background service for persistent downloads
      await _backgroundService.startService();

      // Start download asynchronously (don't await)
      _downloadService.startDownload(
        task,
        media,
        onProgress: (updatedTask) {
          _updateTaskThrottled(updatedTask, notificationId);
        },
        onComplete: (updatedTask) {
          _updateTask(updatedTask);

          // Haptic feedback & Notification
          HapticFeedback.lightImpact();
          _backgroundService.showCompleteNotification(
            title: updatedTask.fileName,
            downloadId: notificationId,
            taskId: updatedTask.id,
            savePath: updatedTask.savePath,
          );

          // Global UI Notification
          try {
            scaffoldMessengerKey.currentState?.showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    const Text('Download complete!'),
                  ],
                ),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
                action: SnackBarAction(
                  label: 'OPEN',
                  textColor: Colors.white,
                  onPressed: () => OpenFilex.open(updatedTask.savePath),
                ),
                backgroundColor: Colors.green.shade800,
              ),
            );
          } catch (_) {}

          // Start next queued download
          _startNextQueuedDownload();
          // Stop service if no more downloads
          if (!hasActiveDownloads && !hasPausedDownloads) {
            _backgroundService.stopService();
          }
        },
        onError: (updatedTask) {
          _updateTask(updatedTask);
          // Show error notification (but not for paused)
          if (updatedTask.status != DownloadStatus.paused) {
            _backgroundService.showFailedNotification(
              title: updatedTask.fileName,
              error: updatedTask.error ?? 'Unknown error',
              downloadId: notificationId,
              taskId: updatedTask.id,
            );
          }
          // Start next queued download
          _startNextQueuedDownload();
          // Stop service if no more downloads
          if (!hasActiveDownloads && !hasPausedDownloads) {
            _backgroundService.stopService();
          }
        },
      );
    } catch (e, stackTrace) {
      debugPrint('❌ startDownload failed: $e');
      debugPrint(stackTrace.toString());
      try {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Failed to start download: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (_) {}
    }
  }

  /// Start the next queued download
  Future<void> _startNextQueuedDownload() async {
    // Check concurrent download limit to prevent race conditions
    final activeCount = _downloads
        .where(
          (d) =>
              d.status == DownloadStatus.downloading ||
              d.status == DownloadStatus.merging,
        )
        .length;
    if (activeCount >= _maxConcurrentDownloads) return;

    final pendingDownloads = _downloads
        .where((d) => d.status == DownloadStatus.pending)
        .toList();
    if (pendingDownloads.isNotEmpty) {
      final nextTask = pendingDownloads.first;
      final media = _mediaMap[nextTask.id];
      if (media != null) {
        // Ensure foreground service is running for queued downloads
        await _backgroundService.startService();

        // Resume the pending download
        final notificationId = _notificationId++;
        _downloadService.startDownload(
          nextTask,
          media,
          onProgress: (updatedTask) {
            _updateTaskThrottled(updatedTask, notificationId);
          },
          onComplete: (updatedTask) {
            _updateTask(updatedTask);

            HapticFeedback.lightImpact();
            _backgroundService.showCompleteNotification(
              title: updatedTask.fileName,
              downloadId: notificationId,
              taskId: updatedTask.id,
              savePath: updatedTask.savePath,
            );

            try {
              scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      const Text('Download complete!'),
                    ],
                  ),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 3),
                  action: SnackBarAction(
                    label: 'OPEN',
                    textColor: Colors.white,
                    onPressed: () => OpenFilex.open(updatedTask.savePath),
                  ),
                  backgroundColor: Colors.green.shade800,
                ),
              );
            } catch (_) {}

            _startNextQueuedDownload();
            if (!hasActiveDownloads && !hasPausedDownloads) {
              _backgroundService.stopService();
            }
          },
          onError: (updatedTask) {
            _updateTask(updatedTask);
            if (updatedTask.status != DownloadStatus.paused) {
              _backgroundService.showFailedNotification(
                title: updatedTask.fileName,
                error: updatedTask.error ?? 'Unknown error',
                downloadId: notificationId,
                taskId: updatedTask.id,
              );
            }
            _startNextQueuedDownload();
            if (!hasActiveDownloads && !hasPausedDownloads) {
              _backgroundService.stopService();
            }
          },
        );
      } else {
        nextTask.status = DownloadStatus.failed;
        nextTask.error = 'Cannot resume queued task: media metadata missing';
        nextTask.statusMessage = null;
        _updateTask(nextTask);
        unawaited(_saveToHistory(nextTask));
      }
    }
  }

  /// Update progress - optimized for smooth UI and proper notification updates
  void _updateTaskThrottled(DownloadTask updatedTask, int notificationId) {
    final index = _downloads.indexWhere((d) => d.id == updatedTask.id);
    if (index != -1) {
      // Always update internal state immediately
      _downloads[index] = updatedTask;

      // Update per-download progress notifier (for granular UI updates)
      _progressNotifiers[updatedTask.id]?.value = updatedTask.progress;

      if (updatedTask.status == DownloadStatus.downloading ||
          updatedTask.status == DownloadStatus.merging ||
          updatedTask.status == DownloadStatus.pending) {
        final now = DateTime.now();
        final lastSnapshotAt = _lastHistorySnapshotTimes[updatedTask.id];
        if (lastSnapshotAt == null ||
            now.difference(lastSnapshotAt) >= const Duration(seconds: 5)) {
          _lastHistorySnapshotTimes[updatedTask.id] = now;
          unawaited(_saveToHistory(updatedTask, refreshHistory: false));
        }
      }

      // Check if progress changed enough for notification update
      final lastProgress = _lastProgressValues[updatedTask.id] ?? 0.0;
      final progressDiff = (updatedTask.progress - lastProgress).abs();

      final now = DateTime.now();
      final lastNotificationTime = _lastNotificationTimes[updatedTask.id];
      final timeSinceLastNotification = lastNotificationTime == null
          ? 1000
          : now.difference(lastNotificationTime).inMilliseconds;

      // Update notification every 2% with detailed info, but throttle to max once per 500ms
      if ((progressDiff >= 0.02 && timeSinceLastNotification >= 500) ||
          updatedTask.status == DownloadStatus.merging ||
          updatedTask.progress >= 1.0) {
        _lastProgressValues[updatedTask.id] = updatedTask.progress;
        _lastNotificationTimes[updatedTask.id] = now;

        // Calculate download speed
        int? speedBytesPerSec;
        final lastBytes = _lastBytesValues[updatedTask.id] ?? 0;
        final lastTime = _lastTimeValues[updatedTask.id];

        if (lastTime != null && updatedTask.downloadedBytes > lastBytes) {
          final elapsedMs = now.difference(lastTime).inMilliseconds;
          if (elapsedMs > 0) {
            speedBytesPerSec =
                ((updatedTask.downloadedBytes - lastBytes) * 1000 ~/ elapsedMs);
          }
        }

        _lastBytesValues[updatedTask.id] = updatedTask.downloadedBytes;
        _lastTimeValues[updatedTask.id] = now;

        _backgroundService.updateProgressDetailed(
          title: updatedTask.fileName,
          progress: updatedTask.progress,
          downloadedBytes: updatedTask.downloadedBytes,
          totalBytes: updatedTask.totalBytes,
          isMerging: updatedTask.status == DownloadStatus.merging,
          downloadId: notificationId,
          taskId: updatedTask.id,
          isPaused: updatedTask.status == DownloadStatus.paused,
          speedBytesPerSec: speedBytesPerSec,
        );

        // Trigger UI update (throttled)
        _throttledNotify();
      }
    }
  }

  void _updateTask(DownloadTask updatedTask) {
    final index = _downloads.indexWhere((d) => d.id == updatedTask.id);
    if (index != -1) {
      _downloads[index] = updatedTask;
      _lastProgressValues.remove(updatedTask.id); // Clean up
      _lastHistorySnapshotTimes.remove(updatedTask.id);

      // Save to history when completed or failed
      if (updatedTask.status == DownloadStatus.completed ||
          updatedTask.status == DownloadStatus.failed) {
        unawaited(_saveToHistory(updatedTask));
      }

      _immediateNotify(); // Important state change - immediate update
    }
  }

  /// Pause a download
  void pauseDownload(String taskId) {
    _downloadService.pauseDownload(taskId);
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index != -1) {
      _downloads[index].status = DownloadStatus.paused;
      _downloads[index].statusMessage = 'Paused';
      _immediateNotify();
      unawaited(_saveToHistory(_downloads[index], refreshHistory: false));

      // Update notification to show "Paused"
      _backgroundService.updateProgressDetailed(
        title: _downloads[index].fileName,
        progress: _downloads[index].progress,
        downloadedBytes: _downloads[index].downloadedBytes,
        totalBytes: _downloads[index].totalBytes,
        isMerging: false,
        downloadId: index, // Might be inexact, but allows update
        taskId: taskId,
        isPaused: true,
      );
    }
  }

  /// Resume a paused download - refetches fresh URLs to handle expiration
  Future<void> resumeDownload(String taskId) async {
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index == -1) return;

    final task = _downloads[index];
    final media = _mediaMap[taskId];

    if (media == null) {
      // Can't resume without media info
      task.status = DownloadStatus.failed;
      task.error = 'Cannot resume: media info not available';
      _immediateNotify();
      unawaited(_saveToHistory(task));
      return;
    }

    // Check concurrent download limit before resuming
    final activeCount = _downloads
        .where(
          (d) =>
              d.status == DownloadStatus.downloading ||
              d.status == DownloadStatus.merging,
        )
        .length;
    if (activeCount >= _maxConcurrentDownloads) {
      // Queue it as pending instead of starting immediately
      task.status = DownloadStatus.pending;
      task.statusMessage = 'Queued...';
      _immediateNotify();
      await _saveToHistory(task);
      return;
    }

    // Update status to show we're preparing to resume
    task.status = DownloadStatus.downloading;
    task.statusMessage = 'Refreshing URLs...';
    _immediateNotify();
    unawaited(_saveToHistory(task, refreshHistory: false));

    // For YouTube videos, refetch fresh URLs (they expire after ~6 hours)
    DetectedMedia freshMedia = media;
    if (media.source == MediaSource.youtube && media.url.isNotEmpty) {
      final tempService = BackendDownloadService();
      try {
        final quality = media.backendQuality ?? 'best';
        final extractionUrl = (media.videoId != null && media.videoId!.isNotEmpty)
            ? 'https://www.youtube.com/watch?v=${media.videoId}'
            : media.url;
        final directUrls = await tempService
            .getDirectUrls(extractionUrl, quality)
            .timeout(const Duration(seconds: 15));

        if (directUrls != null) {
          freshMedia = media.copyWith(
            url: extractionUrl,
            isDash: directUrls.needsMerge,
            videoId: directUrls.videoId,
          );
          _mediaMap[taskId] = freshMedia;
          await _historyService.saveMediaForTask(taskId, freshMedia);
          debugPrint('✅ Refreshed URLs for resume: ${media.title}');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to refresh URLs, trying with cached: $e');
      } finally {
        tempService.dispose();
      }
    }

    // Store media in download service for resume
    _downloadService.storeMedia(taskId, freshMedia);

    final notificationId = _notificationId++;

    // Start background service
    await _backgroundService.startService();

    // Clear paused state and resume download
    _downloadService.clearPausedState(taskId);

    // Resume download with fresh media
    _downloadService.startDownload(
      task,
      freshMedia,
      onProgress: (updatedTask) {
        _updateTaskThrottled(updatedTask, notificationId);
      },
      onComplete: (updatedTask) {
        _updateTask(updatedTask);
        _backgroundService.showCompleteNotification(
          title: updatedTask.fileName,
          downloadId: notificationId,
          taskId: updatedTask.id,
          savePath: updatedTask.savePath,
        );
        _startNextQueuedDownload();
        if (!hasActiveDownloads && !hasPausedDownloads) {
          _backgroundService.stopService();
        }
      },
      onError: (updatedTask) {
        _updateTask(updatedTask);
        if (updatedTask.status != DownloadStatus.paused) {
          _backgroundService.showFailedNotification(
            title: updatedTask.fileName,
            error: updatedTask.error ?? 'Unknown error',
            downloadId: notificationId,
            taskId: updatedTask.id,
          );
        }
        _startNextQueuedDownload();
        if (!hasActiveDownloads && !hasPausedDownloads) {
          _backgroundService.stopService();
        }
      },
    );
  }

  /// Retry a failed download
  Future<void> retryDownload(String taskId) async {
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index == -1) return;

    final media = _mediaMap[taskId];
    if (media == null) {
      return;
    }

    // Remove old task and start fresh
    _downloads.removeAt(index);
    _mediaMap.remove(taskId);
    _lastProgressValues.remove(taskId);
    _lastHistorySnapshotTimes.remove(taskId);
    _progressNotifiers[taskId]?.dispose();
    _progressNotifiers.remove(taskId);
    unawaited(_historyService.removeFromHistory(taskId));
    unawaited(_historyService.removeMediaForTask(taskId));
    _immediateNotify();

    await startDownload(media);
  }

  /// Cancel a download
  void cancelDownload(String taskId) {
    _downloadService.cancelDownload(taskId);
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index != -1) {
      _downloads[index].status = DownloadStatus.cancelled;
      _downloads[index].statusMessage = 'Cancelled';
      unawaited(_saveToHistory(_downloads[index]));
      _mediaMap.remove(taskId);
      _lastProgressValues.remove(taskId);
      _lastHistorySnapshotTimes.remove(taskId);
      _progressNotifiers[taskId]?.dispose();
      _progressNotifiers.remove(taskId);
      unawaited(_historyService.removeMediaForTask(taskId));
      _immediateNotify();
    }
  }

  /// Remove a download from the list (and history for consistency)
  Future<void> removeDownload(String taskId) async {
    _downloads.removeWhere((d) => d.id == taskId);
    _mediaMap.remove(taskId);
    _lastProgressValues.remove(taskId);
    _lastHistorySnapshotTimes.remove(taskId);
    _progressNotifiers[taskId]?.dispose();
    _progressNotifiers.remove(taskId);

    // Also remove from persisted history to prevent orphaned entries
    await _historyService.removeFromHistory(taskId);
    await _historyService.removeMediaForTask(taskId);
    _historyDownloads.removeWhere((d) => d.id == taskId);

    _immediateNotify();
  }

  /// Delete downloaded file and remove from list AND history
  Future<void> deleteDownload(String taskId) async {
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index != -1) {
      await _downloadService.deleteFile(_downloads[index].savePath);
      // Also delete temp file if exists
      final tempPath = _downloads[index].tempPath;
      if (tempPath != null) {
        await _downloadService.deleteFile(tempPath);
      }
      _downloads.removeAt(index);
      _mediaMap.remove(taskId);
      _lastProgressValues.remove(taskId);
      _lastHistorySnapshotTimes.remove(taskId);
    }

    // Also remove from persisted history
    await _historyService.removeFromHistory(taskId);
    await _historyService.removeMediaForTask(taskId);
    _historyDownloads.removeWhere((d) => d.id == taskId);
    _immediateNotify();
  }

  /// Delete a download from history only (file may not exist anymore)
  Future<void> deleteHistoryItem(String taskId) async {
    // Try to delete the file if it exists
    final historyItem = _historyDownloads.firstWhere(
      (d) => d.id == taskId,
      orElse: () => _downloads.firstWhere(
        (d) => d.id == taskId,
        orElse: () => DownloadTask(
          id: '',
          url: '',
          fileName: '',
          savePath: '',
          status: DownloadStatus.cancelled,
        ),
      ),
    );

    if (historyItem.savePath.isNotEmpty) {
      await _downloadService.deleteFile(historyItem.savePath);
      if (historyItem.tempPath != null) {
        await _downloadService.deleteFile(historyItem.tempPath!);
      }
    }

    // Remove from current downloads if present
    _downloads.removeWhere((d) => d.id == taskId);
    _mediaMap.remove(taskId);
    _lastProgressValues.remove(taskId);
    _lastHistorySnapshotTimes.remove(taskId);

    // Remove from persisted history
    await _historyService.removeFromHistory(taskId);
    await _historyService.removeMediaForTask(taskId);
    _historyDownloads.removeWhere((d) => d.id == taskId);
    _immediateNotify();
  }

  /// Clear completed downloads from the list
  void clearCompleted() {
    final toRemove = _downloads
        .where(
          (d) =>
              d.status == DownloadStatus.completed ||
              d.status == DownloadStatus.failed ||
              d.status == DownloadStatus.cancelled,
        )
        .map((d) => d.id)
        .toList();

    for (final id in toRemove) {
      _mediaMap.remove(id);
      _lastProgressValues.remove(id);
      _lastHistorySnapshotTimes.remove(id);
      unawaited(_historyService.removeMediaForTask(id));
    }

    _downloads.removeWhere(
      (d) =>
          d.status == DownloadStatus.completed ||
          d.status == DownloadStatus.failed ||
          d.status == DownloadStatus.cancelled,
    );
    _immediateNotify();
  }

  /// Clear all download history
  Future<void> clearHistory() async {
    await _historyService.clearHistory();
    _historyDownloads.clear();
    _mediaMap.clear();
    _lastHistorySnapshotTimes.clear();
    _immediateNotify();
  }

  /// Cancel all active downloads
  void cancelAllDownloads() {
    _downloadService.cancelAllDownloads();
    for (final download in activeDownloads) {
      download.status = DownloadStatus.cancelled;
      download.statusMessage = 'Cancelled';
      _lastProgressValues.remove(download.id);
      _lastHistorySnapshotTimes.remove(download.id);
      unawaited(_saveToHistory(download, refreshHistory: false));
      unawaited(_historyService.removeMediaForTask(download.id));
    }
    _backgroundService.stopService();
    _immediateNotify();
  }

  /// Pause all active downloads
  void pauseAllDownloads() {
    for (final download in activeDownloads) {
      if (download.status == DownloadStatus.downloading) {
        pauseDownload(download.id);
      }
    }
  }

  /// Resume all paused downloads
  Future<void> resumeAllDownloads() async {
    for (final download in pausedDownloads) {
      await resumeDownload(download.id);
    }
  }

  @override
  void dispose() {
    _updateThrottleTimer?.cancel();
    _actionPort.close();
    IsolateNameServer.removePortNameMapping('download_actions_port');
    _lastProgressValues.clear();
    _lastBytesValues.clear();
    _lastTimeValues.clear();
    _lastNotificationTimes.clear();
    _lastHistorySnapshotTimes.clear();
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();
    _downloadService.dispose();
    super.dispose();
  }
}
