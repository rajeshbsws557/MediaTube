import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import 'backend_download_service.dart';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Service to manage file downloads with pause/resume support
class DownloadService {
  final Dio _dio = Dio();

  final BackendDownloadService _backendService = BackendDownloadService();
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, BackendCancelToken> _backendCancelTokens = {};
  final Map<String, bool> _pausedDownloads = {}; // Track paused state
  final Map<String, DetectedMedia> _downloadMedia =
      {}; // Store media for resume

  // Backend server settings
  bool? _backendAvailable; // Cache backend availability

  // Download directory
  String? _downloadPath;

  // Headers required for YouTube downloads
  static const Map<String, String> _defaultHeaders = {
    // Keep the Pixel 7 User-Agent
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': '*/*',
    'Connection': 'keep-alive',
    // UPDATED: Use Mobile domain to match User-Agent
    'Referer': 'https://m.youtube.com/',
    'Origin': 'https://m.youtube.com',
  };

  Future<String> get downloadPath async {
    if (_downloadPath != null) return _downloadPath!;

    // Try to get the Downloads folder, fall back to app documents
    try {
      if (Platform.isAndroid) {
        // Android external storage Downloads folder
        final dir = Directory('/storage/emulated/0/Download/MediaTube');
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        // Verify the directory is writable by creating a test file
        final testFile = File('${dir.path}/.write_test');
        await testFile.writeAsString('test');
        await testFile.delete();
        _downloadPath = dir.path;
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final downloadDir = Directory(p.join(dir.path, 'MediaTube'));
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }
        _downloadPath = downloadDir.path;
      }
    } catch (e) {
      debugPrint('⚠️ Failed to use external storage: $e');
      // Fallback to app-private documents directory (always writable)
      final dir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory(p.join(dir.path, 'MediaTube'));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      _downloadPath = downloadDir.path;
      debugPrint('📁 Using fallback download path: $_downloadPath');
    }

    return _downloadPath!;
  }

  /// Ensure download directory exists (call before any download)
  Future<void> ensureDownloadDirectory() async {
    final path = await downloadPath;
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('⚠️ Failed to create download dir: $e');
      // Reset cached path so downloadPath getter retries with fallback
      _downloadPath = null;
      await downloadPath; // This will use fallback
    }
  }

  /// Create a download task without starting the download
  Future<DownloadTask> createDownloadTask(DetectedMedia media) async {
    await ensureDownloadDirectory(); // Ensure folder exists
    final taskId = const Uuid().v4();
    final basePath = await downloadPath;
    final sanitizedTitle = _sanitizeFileName(media.title);
    final fileName = '$sanitizedTitle.${media.extension}';
    final savePath = p.join(basePath, fileName);

    return DownloadTask(
      id: taskId,
      url: media.url,
      fileName: fileName,
      savePath: savePath,
      audioUrl: media.audioUrl,
      requiresMerge:
          media.isDash && media.audioUrl != null && !media.useBackend,
      status: DownloadStatus.pending,
    );
  }

  /// Check if backend server is available
  Future<bool> isBackendAvailable() async {
    _backendAvailable ??= await _backendService.isServerAvailable();
    return _backendAvailable!;
  }

  /// Set backend server URL
  void setBackendServerUrl(String url) {
    BackendDownloadService.setServerUrl(url);
    _backendAvailable = null; // Reset cache
  }

  /// Get current backend server URL
  String get backendServerUrl => BackendDownloadService.serverUrl;

  /// Get backend download service (for UI access)
  BackendDownloadService get backendService => _backendService;

  /// Update the foreground notification text
  void _updateNotification(String title, String text, double progress) {
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Start downloading a media file (call after createDownloadTask)
  /// ALWAYS uses backend for YouTube - NO FALLBACKS
  Future<void> startDownload(
    DownloadTask task,
    DetectedMedia media, {
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
  }) async {
    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;
    _pausedDownloads[task.id] = false;
    _downloadMedia[task.id] = media;

    // Create backend cancel token for YouTube downloads
    final backendCancelToken = BackendCancelToken();
    _backendCancelTokens[task.id] = backendCancelToken;

    task.status = DownloadStatus.downloading;
    onProgress?.call(task);

    // Note: Foreground service is managed by DownloadProvider via BackgroundDownloadService

    debugPrint('Starting download: ${media.title}');
    debugPrint('Source: ${media.source}, VideoId: ${media.videoId}');

    try {
      if (media.source == MediaSource.youtube) {
        if (media.useBackend == false && media.url.isNotEmpty) {
          // Audio-only streams: already have direct CDN URL from youtube_explode
          // Use backend's fast parallel download engine, skip URL re-extraction
          debugPrint('🎵 Direct audio download (skipping re-extraction)');
          await _backendService.downloadDirectFromUrl(
            task,
            media.url,
            savePath: task.savePath,
            onProgress: (t) {
              _updateNotification(
                'Downloading ${media.title}',
                '${(t.progress * 100).toInt()}%',
                t.progress,
              );
              onProgress?.call(t);
            },
            onComplete: (t) {
              _cleanup(task.id);
              onComplete?.call(t);
            },
            onError: (t) {
              _cleanup(task.id);
              onError?.call(t);
            },
            cancelToken: backendCancelToken,
          );
        } else {
          // Video streams: need backend to extract/merge DASH streams
          debugPrint('🌐 Using backend server for YouTube download');
          await _backendService.downloadDirect(
            task,
            media,
            savePath: task.savePath,
            onProgress: (t) {
              _updateNotification(
                'Downloading ${media.title}',
                '${(t.progress * 100).toInt()}%',
                t.progress,
              );
              onProgress?.call(t);
            },
            onComplete: (t) {
              _cleanup(task.id);
              onComplete?.call(t);
            },
            onError: (t) {
              _cleanup(task.id);
              onError?.call(t);
            },
            cancelToken: backendCancelToken,
          );
        }
        return; // Backend handles completion/error callbacks
      }

      // Non-YouTube sources - direct download
      debugPrint('Using direct download for non-YouTube source');
      task = await _downloadSingleFileResumable(task, (t) {
        _updateNotification(
          'Downloading ${media.title}',
          '${(t.progress * 100).toInt()}%',
          t.progress,
        );
        onProgress?.call(t);
      }, cancelToken);

      // Check if paused
      if (_pausedDownloads[task.id] == true) {
        task.status = DownloadStatus.paused;
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      debugPrint('Download completed: ${media.title}');
      _cleanup(task.id);
      onComplete?.call(task);
    } catch (e, stackTrace) {
      debugPrint('Download error: $e');
      debugPrint('Stack trace: $stackTrace');
      if (_pausedDownloads[task.id] == true) {
        task.status = DownloadStatus.paused;
        onProgress?.call(task);
      } else if (e is DioException && e.type == DioExceptionType.cancel) {
        task.status = DownloadStatus.cancelled;
        _cleanup(task.id);
        onError?.call(task);
      } else {
        task.status = DownloadStatus.failed;
        task.error = e.toString();
        _cleanup(task.id);
        onError?.call(task);
      }
    }
  }

  void _cleanup(String taskId) {
    _cancelTokens.remove(taskId);
    _backendCancelTokens.remove(taskId);
    _pausedDownloads.remove(taskId);
    _downloadMedia.remove(taskId);
  }

  /// Pause a download
  void pauseDownload(String taskId) {
    _pausedDownloads[taskId] = true;
    // Cancel the Dio cancel token (for non-YouTube downloads)
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Paused');
    }
    // Cancel the backend cancel token (for YouTube downloads)
    final backendToken = _backendCancelTokens[taskId];
    if (backendToken != null && !backendToken.isCancelled) {
      backendToken.cancel('Paused');
    }
  }

  /// Check if download is paused
  bool isDownloadPaused(String taskId) => _pausedDownloads[taskId] == true;

  /// Get stored media for resume
  DetectedMedia? getStoredMedia(String taskId) => _downloadMedia[taskId];

  /// Store media for a task (used when resuming)
  void storeMedia(String taskId, DetectedMedia media) {
    _downloadMedia[taskId] = media;
  }

  /// Clear the paused state for a task (used when resuming)
  void clearPausedState(String taskId) {
    _pausedDownloads.remove(taskId);
    _backendCancelTokens.remove(taskId); // Remove old cancelled token
  }

  /// Download a media file (legacy method for compatibility)
  Future<DownloadTask> downloadMedia(
    DetectedMedia media, {
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
  }) async {
    final task = await createDownloadTask(media);
    await startDownload(
      task,
      media,
      onProgress: onProgress,
      onComplete: onComplete,
      onError: onError,
    );
    return task;
  }

  Future<DownloadTask> _downloadSingleFileResumable(
    DownloadTask task,
    Function(DownloadTask)? onProgress,
    CancelToken cancelToken,
  ) async {
    final tempPath = '${task.savePath}.part';
    task.tempPath = tempPath;

    final tempFile = File(tempPath);
    int downloadedBytes = 0;

    // Check if partial file exists for resume
    if (await tempFile.exists()) {
      downloadedBytes = await tempFile.length();
      task.downloadedBytes = downloadedBytes;
    }

    // Get total file size first
    try {
      final headResponse = await _dio.head(
        task.url,
        options: Options(headers: _defaultHeaders),
      );
      final contentLength = headResponse.headers.value('content-length');
      if (contentLength != null) {
        task.totalBytes = int.tryParse(contentLength) ?? 0;
      }
    } catch (_) {}

    // Check if server supports range requests
    final supportsRange = task.totalBytes > 0;

    if (supportsRange &&
        downloadedBytes > 0 &&
        downloadedBytes < task.totalBytes) {
      // Resume download - use streaming to append to existing file
      debugPrint('Resuming download from $downloadedBytes bytes');
      final headers = Map<String, dynamic>.from(_defaultHeaders);
      headers['Range'] = 'bytes=$downloadedBytes-';

      final response = await _dio.get<ResponseBody>(
        task.url,
        options: Options(headers: headers, responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );

      final file = File(tempPath);
      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      int received = 0;
      try {
        await for (final chunk in response.data!.stream) {
          if (_pausedDownloads[task.id] == true) {
            cancelToken.cancel('Paused');
            break;
          }
          sink.add(chunk);
          received += chunk.length;
          final totalReceived = downloadedBytes + received;
          task.downloadedBytes = totalReceived;
          if (task.totalBytes > 0) {
            task.progress = totalReceived / task.totalBytes;
            onProgress?.call(task);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } else {
      // Fresh download
      await _dio.download(
        task.url,
        tempPath,
        cancelToken: cancelToken,
        options: Options(headers: _defaultHeaders),
        deleteOnError: false,
        onReceiveProgress: (received, total) {
          if (_pausedDownloads[task.id] == true) {
            cancelToken.cancel('Paused');
            return;
          }
          task.downloadedBytes = received;
          if (total > 0) {
            task.totalBytes = total;
            task.progress = received / total;
            onProgress?.call(task);
          }
        },
      );
    }

    // If not paused, rename temp file to final
    if (_pausedDownloads[task.id] != true) {
      final finalFile = File(task.savePath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFile.rename(task.savePath);
    }

    return task;
  }

  /// Cancel a download
  void cancelDownload(String taskId) {
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Download cancelled by user');
    }
    final backendToken = _backendCancelTokens[taskId];
    if (backendToken != null && !backendToken.isCancelled) {
      backendToken.cancel('Download cancelled by user');
    }
  }

  /// Cancel all downloads
  void cancelAllDownloads() {
    for (final token in _cancelTokens.values) {
      if (!token.isCancelled) {
        token.cancel('All downloads cancelled');
      }
    }
    for (final token in _backendCancelTokens.values) {
      if (!token.isCancelled) {
        token.cancel('All downloads cancelled');
      }
    }
    _cancelTokens.clear();
    _backendCancelTokens.clear();
  }

  /// Get list of downloaded files
  Future<List<File>> getDownloadedFiles() async {
    final path = await downloadPath;
    final dir = Directory(path);

    if (!await dir.exists()) {
      return [];
    }

    final files = await dir.list().where((entity) => entity is File).toList();
    return files.cast<File>();
  }

  /// Delete a downloaded file
  Future<bool> deleteFile(String filePath) async {
    return _deleteFile(filePath);
  }

  Future<bool> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } catch (e) {
      debugPrint('Error deleting file: $e');
    }
    return false;
  }

  String _sanitizeFileName(String name) {
    // Remove invalid characters for file names on Windows/Android
    // Including: < > : " / \ | ? * and control characters
    var sanitized = name
        .replaceAll(
          RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
          '_',
        ) // Replace invalid chars with underscore
        .replaceAll(RegExp(r'[\s]+'), '_') // Replace whitespace with underscore
        .replaceAll(RegExp(r'_+'), '_') // Collapse multiple underscores
        .replaceAll(
          RegExp(r'^_+|_+$'),
          '',
        ); // Trim leading/trailing underscores

    // Truncate to max 100 characters
    if (sanitized.length > 100) {
      sanitized = sanitized.substring(0, 100);
    }
    // If empty, use a default name
    if (sanitized.isEmpty) {
      sanitized = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
    return sanitized;
  }

  void dispose() {
    cancelAllDownloads();
    _dio.close();
  }
}

// Top-level callback for foreground task
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(NotificationHandler());
}

class NotificationHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // foreground task initialized
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // not needed for simple notification
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // foreground task destroyed
  }

  @override
  void onNotificationPressed() {
    // Launch app main screen
    FlutterForegroundTask.launchApp();
  }
}
