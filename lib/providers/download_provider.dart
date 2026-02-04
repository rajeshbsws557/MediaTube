import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../services/services.dart';

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

  // Throttling - reduced frequency for smoother UI (was 100ms)
  Timer? _updateThrottleTimer;
  bool _pendingNotify = false;
  static const _updateThrottleDuration = Duration(milliseconds: 250);

  // Per-download progress notifiers for granular UI updates without full rebuilds
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};

  // Track last progress values to avoid unnecessary updates
  final Map<String, double> _lastProgressValues = {};

  // Limit concurrent downloads to reduce CPU load
  static const int _maxConcurrentDownloads = 2;

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
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyDownloads = await _historyService.getHistory();
    _historyLoaded = true;
    notifyListeners();
  }

  Future<void> _saveToHistory(DownloadTask task) async {
    await _historyService.saveDownload(task);
    // Refresh history
    _historyDownloads = await _historyService.getHistory();
  }

  /// Start downloading a media file with concurrent download limiting
  Future<void> startDownload(DetectedMedia media) async {
    final task = await _downloadService.createDownloadTask(media);
    final notificationId = _notificationId++;
    _downloads.insert(0, task);
    _mediaMap[task.id] = media; // Store media for retry/resume
    _progressNotifiers[task.id] = ValueNotifier<double>(
      0.0,
    ); // Create progress notifier
    _immediateNotify(); // Immediate update when new download added

    // Check concurrent download limit
    final currentlyDownloading = _downloads
        .where(
          (d) =>
              d.status == DownloadStatus.downloading ||
              d.status == DownloadStatus.merging,
        )
        .length;

    if (currentlyDownloading > _maxConcurrentDownloads) {
      // Queue this download - it will stay in pending state
      task.status = DownloadStatus.pending;
      task.statusMessage = 'Queued...';
      notifyListeners();

      // Wait for a slot to open up
      await _waitForDownloadSlot(task.id);
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
        // Show complete notification
        _backgroundService.showCompleteNotification(
          title: updatedTask.fileName,
          downloadId: notificationId,
        );
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
          );
        }
        // Stop service if no more downloads
        if (!hasActiveDownloads && !hasPausedDownloads) {
          _backgroundService.stopService();
        }
      },
    );
  }

  /// Wait for a download slot to open up
  Future<void> _waitForDownloadSlot(String taskId) async {
    while (true) {
      final downloading = _downloads
          .where(
            (d) =>
                d.status == DownloadStatus.downloading ||
                d.status == DownloadStatus.merging,
          )
          .length;

      if (downloading < _maxConcurrentDownloads) {
        break;
      }

      // Check if this task was cancelled
      final task = _downloads.firstWhere(
        (d) => d.id == taskId,
        orElse: () => DownloadTask(
          id: '',
          url: '',
          fileName: '',
          savePath: '',
          status: DownloadStatus.cancelled,
        ),
      );
      if (task.status == DownloadStatus.cancelled) {
        break;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Start the next queued download
  void _startNextQueuedDownload() {
    final pendingDownloads = _downloads
        .where((d) => d.status == DownloadStatus.pending)
        .toList();
    if (pendingDownloads.isNotEmpty) {
      final nextTask = pendingDownloads.first;
      final media = _mediaMap[nextTask.id];
      if (media != null) {
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
            _backgroundService.showCompleteNotification(
              title: updatedTask.fileName,
              downloadId: notificationId,
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
              );
            }
            _startNextQueuedDownload();
            if (!hasActiveDownloads && !hasPausedDownloads) {
              _backgroundService.stopService();
            }
          },
        );
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

      // Check if progress changed enough for notification update
      final lastProgress = _lastProgressValues[updatedTask.id] ?? 0.0;
      final progressDiff = (updatedTask.progress - lastProgress).abs();

      // Update notification every 2% with detailed info (reduced from 1%)
      if (progressDiff >= 0.02 ||
          updatedTask.status == DownloadStatus.merging) {
        _lastProgressValues[updatedTask.id] = updatedTask.progress;
        _backgroundService.updateProgressDetailed(
          title: updatedTask.fileName,
          progress: updatedTask.progress,
          downloadedBytes: updatedTask.downloadedBytes,
          totalBytes: updatedTask.totalBytes,
          isMerging: updatedTask.status == DownloadStatus.merging,
          downloadId: notificationId,
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

      // Save to history when completed or failed
      if (updatedTask.status == DownloadStatus.completed ||
          updatedTask.status == DownloadStatus.failed) {
        _saveToHistory(updatedTask);
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
      _immediateNotify();
    }
  }

  /// Resume a paused download
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
      return;
    }

    // Store media in download service for resume
    _downloadService.storeMedia(taskId, media);

    final notificationId = _notificationId++;

    // Start background service
    await _backgroundService.startService();

    // Resume download
    _downloadService.startDownload(
      task,
      media,
      onProgress: (updatedTask) {
        _updateTaskThrottled(updatedTask, notificationId);
      },
      onComplete: (updatedTask) {
        _updateTask(updatedTask);
        _backgroundService.showCompleteNotification(
          title: updatedTask.fileName,
          downloadId: notificationId,
        );
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
          );
        }
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
    _immediateNotify();

    await startDownload(media);
  }

  /// Cancel a download
  void cancelDownload(String taskId) {
    _downloadService.cancelDownload(taskId);
    final index = _downloads.indexWhere((d) => d.id == taskId);
    if (index != -1) {
      _downloads[index].status = DownloadStatus.cancelled;
      _mediaMap.remove(taskId);
      _lastProgressValues.remove(taskId);
      _progressNotifiers[taskId]?.dispose();
      _progressNotifiers.remove(taskId);
      _immediateNotify();
    }
  }

  /// Remove a download from the list
  void removeDownload(String taskId) {
    _downloads.removeWhere((d) => d.id == taskId);
    _mediaMap.remove(taskId);
    _lastProgressValues.remove(taskId);
    _progressNotifiers[taskId]?.dispose();
    _progressNotifiers.remove(taskId);
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
    }

    // Also remove from persisted history
    await _historyService.removeFromHistory(taskId);
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

    // Remove from persisted history
    await _historyService.removeFromHistory(taskId);
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
    _immediateNotify();
  }

  /// Cancel all active downloads
  void cancelAllDownloads() {
    _downloadService.cancelAllDownloads();
    for (final download in activeDownloads) {
      download.status = DownloadStatus.cancelled;
      _lastProgressValues.remove(download.id);
    }
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
    _lastProgressValues.clear();
    _downloadService.dispose();
    super.dispose();
  }
}
