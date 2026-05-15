import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../config/app_config.dart';
import '../models/detected_media.dart';
import '../models/download_task.dart';
import 'download_service.dart';
import 'ffmpeg_service.dart';
import 'native_youtube_service.dart';

/// Cancellation token for backend downloads (independent of Dio's CancelToken)
class BackendCancelToken {
  bool _isCancelled = false;
  bool get isCancelled => _isCancelled;
  String? reason;

  void cancel([String? reason]) {
    _isCancelled = true;
    this.reason = reason;
  }
}

/// Service for downloading YouTube videos.
/// Uses on-device NewPipe Extractor (native) by default, with server fallback.
class BackendDownloadService {
  // Server URL from app configuration (used as fallback)
  static String _serverUrl = AppConfig.backendBaseUrl;

  // Whether to use native on-device extraction (recommended)
  static bool _useNativeExtraction = true;

  final Dio _dio;
  Timer? _progressTimer;

  // Parallel download settings for FAST downloads
  static const int _parallelChunks = 8;
  static const int _minChunkSize = 1024 * 1024; // 1MB minimum chunk size

  BackendDownloadService()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 30),
        ),
      );

  /// Enable or disable native on-device extraction
  static void setUseNativeExtraction(bool value) {
    _useNativeExtraction = value;
  }

  /// Check if native extraction is enabled
  static bool get useNativeExtraction => _useNativeExtraction;

  /// Set the backend server URL (for fallback mode)
  static void setServerUrl(String url) {
    final normalized =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      debugPrint('Rejected invalid backend URL: $url');
      return;
    }

    final scheme = uri.scheme.toLowerCase();
    final allowHttp = kDebugMode;
    if (scheme != 'https' && !(allowHttp && scheme == 'http')) {
      debugPrint('Rejected insecure backend URL in current build mode');
      return;
    }

    _serverUrl = normalized;
  }

  /// Get current server URL
  static String get serverUrl => _serverUrl;

  bool _isSafeNetworkUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// Check if extraction is available (native or server)
  Future<bool> isExtractionAvailable() async {
    if (_useNativeExtraction) {
      return await NativeYoutubeService.isInitialized();
    }
    return await isServerAvailable();
  }

  /// Check if the backend server is available (fallback)
  Future<bool> isServerAvailable() async {
    if (!_isSafeNetworkUrl(_serverUrl)) {
      return false;
    }

    try {
      final response = await _dio.get(
        '$_serverUrl/health',
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Backend server not available: $e');
      return false;
    }
  }

  /// Get server info including yt-dlp version (fallback only)
  Future<Map<String, dynamic>?> getServerInfo() async {
    if (!_isSafeNetworkUrl(_serverUrl)) {
      return null;
    }

    try {
      final response = await _dio.get('$_serverUrl/health');
      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Error getting server info: $e');
    }
    return null;
  }

  /// Get video info and available formats from YouTube
  /// Uses native on-device extraction by default, with server fallback
  Future<BackendVideoInfo?> getVideoInfo(String url) async {
    if (!_isSafeNetworkUrl(url)) {
      debugPrint('Rejected unsafe media URL for extraction');
      return null;
    }

    // Try native extraction first
    if (_useNativeExtraction) {
      try {
        debugPrint('🎬 Using native on-device extraction...');
        final data = await NativeYoutubeService.getVideoInfo(url);
        return BackendVideoInfo.fromJson(data);
      } catch (e) {
        debugPrint(
          '⚠️ Native extraction failed: $e, trying server fallback...',
        );
        // Fall through to server
      }
    }

    // Fallback to server
    try {
      final response = await _dio.get(
        '$_serverUrl/formats',
        queryParameters: {'url': url},
        options: Options(receiveTimeout: const Duration(minutes: 2)),
      );

      if (response.statusCode == 200) {
        return BackendVideoInfo.fromJson(response.data);
      }
    } catch (e) {
      debugPrint('Error getting video info from server: $e');
    }
    return null;
  }

  /// Convert backend video info to DetectedMedia list
  /// Supports Java server (NewPipe Extractor) response format
  Future<List<DetectedMedia>> getAvailableStreams(String url) async {
    final info = await getVideoInfo(url);
    if (info == null) return [];

    final List<DetectedMedia> mediaList = [];

    // Find best available quality from server response
    int? maxHeight;
    for (final fmt in info.formats ?? []) {
      if (fmt.height != null &&
          (maxHeight == null || fmt.height! > maxHeight)) {
        maxHeight = fmt.height;
      }
    }

    // Add best quality option first if we have high quality
    if (maxHeight != null && maxHeight >= 1080) {
      final bestFormat = info.formats?.firstWhere(
        (f) => f.height == maxHeight,
        orElse: () => BackendFormat(),
      );

      mediaList.add(
        DetectedMedia(
          url: url,
          title: info.title ?? 'Unknown',
          type: MediaType.video,
          source: MediaSource.youtube,
          thumbnailUrl: info.thumbnail,
          fileSize:
              bestFormat?.filesize ??
              _estimateFileSize(info.duration ?? 0, maxHeight),
          quality: '${maxHeight}p (Best)',
          format: 'mp4',
          isDash: true,
          videoId: info.id,
          backendQuality: 'best',
        ),
      );
    }

    // Add common quality options
    final qualities = ['1440p', '1080p', '720p', '480p', '360p'];
    for (final quality in qualities) {
      int height = int.parse(quality.replaceAll('p', ''));

      // Only add if this quality is available or lower than best
      if (maxHeight != null && height > maxHeight) continue;

      // Skip if already added as best
      if (maxHeight == height) continue;

      // Check if this quality exists in formats
      final hasQuality = info.formats?.any((f) => f.height == height) ?? false;
      if (!hasQuality && height > 720) {
        continue; // Only show higher qualities if available
      }

      int estimatedSize = _estimateFileSize(info.duration ?? 0, height);

      mediaList.add(
        DetectedMedia(
          url: url,
          title: info.title ?? 'Unknown',
          type: MediaType.video,
          source: MediaSource.youtube,
          thumbnailUrl: info.thumbnail,
          fileSize: estimatedSize,
          quality: '$quality${height >= 720 ? " (HD)" : ""}',
          format: 'mp4',
          isDash: true,
          videoId: info.id,
          backendQuality: quality,
        ),
      );
    }

    // Add audio-only option
    mediaList.add(
      DetectedMedia(
        url: url,
        title: '${info.title} (Audio)',
        type: MediaType.audio,
        source: MediaSource.youtube,
        thumbnailUrl: info.thumbnail,
        fileSize: _estimateFileSize(info.duration ?? 0, 0),
        quality: 'Audio (Best)',
        format: 'm4a',
        isDash: false,
        videoId: info.id,
        backendQuality: 'audio',
      ),
    );

    return mediaList;
  }

  /// Estimate file size based on duration and resolution
  int _estimateFileSize(int durationSeconds, int height) {
    // Rough estimates: bitrate in kbps
    int videoBitrate;
    switch (height) {
      case 0: // Audio only
        return durationSeconds * 16 * 1024; // ~128kbps audio
      case 360:
        videoBitrate = 800;
        break;
      case 480:
        videoBitrate = 1500;
        break;
      case 720:
        videoBitrate = 3000;
        break;
      case 1080:
        videoBitrate = 6000;
        break;
      case 1440:
        videoBitrate = 10000;
        break;
      case 2160:
        videoBitrate = 18000;
        break;
      default:
        videoBitrate = height > 1440 ? 18000 : 8000;
    }
    // Add audio bitrate (~128kbps)
    int totalBitrate = videoBitrate + 128;
    // Convert to bytes: bitrate (kbps) * duration (s) / 8 * 1024
    return (totalBitrate * durationSeconds * 1024 ~/ 8);
  }

  /// Get direct URLs for client-side download (FAST!)
  /// Uses native extraction by default, with server fallback
  Future<DirectUrls?> getDirectUrls(String url, String quality) async {
    if (!_isSafeNetworkUrl(url)) {
      debugPrint('Rejected unsafe media URL for direct extraction');
      return null;
    }

    // Try native extraction first
    if (_useNativeExtraction) {
      try {
        debugPrint('🎬 Getting direct URLs via native extraction...');
        final result = await NativeYoutubeService.getDirectUrls(
          url,
          quality: quality,
        );
        return DirectUrls(
          videoId: result.videoId,
          title: result.title,
          duration: result.duration,
          needsMerge: result.needsMerge,
          videoUrl: result.videoUrl,
          audioUrl: result.audioUrl,
          videoFormat: result.videoFormat,
          audioFormat: result.audioFormat,
          actualQuality: result.actualQuality,
        );
      } catch (e) {
        debugPrint(
          '⚠️ Native direct URLs failed: $e, trying server fallback...',
        );
        // Fall through to server
      }
    }

    // Fallback to server
    try {
      final response = await _dio.get(
        '$_serverUrl/direct',
        queryParameters: {'url': url, 'quality': quality},
        options: Options(receiveTimeout: const Duration(minutes: 2)),
      );

      if (response.statusCode == 200) {
        return DirectUrls.fromJson(response.data);
      }
    } catch (e) {
      debugPrint('Error getting direct URLs from server: $e');
    }
    return null;
  }

  /// FAST direct download - downloads directly from YouTube CDN
  /// Uses backend only for URL extraction, not for file transfer
  Future<void> downloadDirect(
    DownloadTask task,
    DetectedMedia media, {
    required String savePath,
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
    BackendCancelToken? cancelToken,
  }) async {
    try {
      // Check cancellation before starting
      if (cancelToken?.isCancelled == true) {
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.downloading;
      task.statusMessage = 'Getting download URLs...';
      onProgress?.call(task);

      // Get quality from media
      final quality = media.backendQuality ?? 'best';

      debugPrint('🚀 FAST Direct download: ${media.title} @ $quality');

      // Get direct URLs from backend
      final directUrls = await getDirectUrls(media.url, quality);
      if (directUrls == null) {
        throw Exception('Failed to get direct URLs');
      }

      debugPrint(
        '🎬 Direct URL quality: ${directUrls.actualQuality}, needsMerge: ${directUrls.needsMerge}',
      );

      // Ensure parent directory exists before downloading
      final downloadDir = Directory(p.dirname(savePath));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(minutes: 30),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Connection': 'keep-alive',
          },
        ),
      );

      try {
        if (directUrls.needsMerge && directUrls.audioUrl != null) {
          // DASH: Download video + audio separately, then merge
          final actualExt =
              directUrls.videoFormat?.toLowerCase().contains('webm') == true
              ? 'webm'
              : 'mp4';
          var finalSavePath = savePath;
          if (!savePath.toLowerCase().endsWith(actualExt)) {
            finalSavePath = '${p.withoutExtension(savePath)}.$actualExt';
          }
          await _downloadDashDirect(
            task,
            directUrls,
            finalSavePath,
            dio,
            onProgress,
            cancelToken,
          );
        } else {
          // Combined stream: single download
          await _downloadSingleDirect(
            task,
            directUrls.videoUrl,
            savePath,
            dio,
            onProgress,
            cancelToken,
          );
        }
      } finally {
        dio.close();
      }

      // Check if cancelled during download
      if (cancelToken?.isCancelled == true) {
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      task.statusMessage = null;
      debugPrint('✅ Direct download complete: ${media.title}');
      onComplete?.call(task);
    } catch (e, stack) {
      // If cancelled/paused, don't treat as error
      if (cancelToken?.isCancelled == true) {
        debugPrint('⏸️ Download paused: ${media.title}');
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        task.error = null;
        onProgress?.call(task);
        return;
      }
      debugPrint('❌ Direct download error: $e');
      debugPrint(stack.toString());
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      if (onError != null) {
        onError(task);
        return;
      }
      rethrow;
    }
  }

  /// Download directly from a pre-extracted URL (no re-extraction needed)
  /// Used for YouTube audio-only streams that already have CDN URLs
  Future<void> downloadDirectFromUrl(
    DownloadTask task,
    String url, {
    required String savePath,
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
    BackendCancelToken? cancelToken,
  }) async {
    if (!_isSafeNetworkUrl(url)) {
      throw Exception('Blocked unsafe URL scheme');
    }

    try {
      if (cancelToken?.isCancelled == true) {
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.downloading;
      task.statusMessage = 'Downloading audio...';
      onProgress?.call(task);

      debugPrint('🎵 Direct URL download started');

      // Ensure parent directory exists
      final downloadDir = Directory(p.dirname(savePath));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      // Use fast parallel download engine (same as video downloads)
      await _downloadParallel(
        url: url,
        savePath: savePath,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (total > 0) {
            task.progress = received / total;
            task.downloadedBytes = received;
            task.totalBytes = total;
            onProgress?.call(task);
          }
        },
      );

      if (cancelToken?.isCancelled == true) {
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      task.statusMessage = null;
      debugPrint('✅ Direct URL download complete');
      onComplete?.call(task);
    } catch (e, stack) {
      if (cancelToken?.isCancelled == true) {
        task.status = DownloadStatus.paused;
        task.statusMessage = 'Paused';
        task.error = null;
        onProgress?.call(task);
        return;
      }
      debugPrint('❌ Direct URL download error: $e');
      debugPrint(stack.toString());
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      if (onError != null) {
        onError(task);
        return;
      }
      rethrow;
    }
  }

  /// Download a single combined stream directly - FAST parallel chunks
  Future<void> _downloadSingleDirect(
    DownloadTask task,
    String url,
    String savePath,
    Dio dio,
    Function(DownloadTask)? onProgress,
    BackendCancelToken? cancelToken,
  ) async {
    task.statusMessage = 'Downloading...';
    onProgress?.call(task);

    // Use fast parallel download
    await _downloadParallel(
      url: url,
      savePath: savePath,
      cancelToken: cancelToken,
      onProgress: (received, total) {
        if (total > 0) {
          task.progress = received / total;
          task.downloadedBytes = received;
          task.totalBytes = total;
          onProgress?.call(task);
        }
      },
    );
  }

  /// FAST parallel download - downloads file in multiple chunks simultaneously
  /// This mimics what SnapTube and other fast downloaders do
  Future<void> _downloadParallel({
    required String url,
    required String savePath,
    required void Function(int received, int total) onProgress,
    BackendCancelToken? cancelToken,
    int chunks = _parallelChunks,
  }) async {
    if (!_isSafeNetworkUrl(url)) {
      throw Exception('Blocked unsafe URL scheme');
    }

    debugPrint('🚀 Starting parallel download with $chunks connections');

    // Check cancellation early
    if (cancelToken?.isCancelled == true) return;

    // First, get the file size with a HEAD request
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 30),
        headers: DownloadService.defaultHeaders,
      ),
    );

    int totalSize = 0;
    bool supportsRange = false;

    try {
      // Try HEAD request first
      final headResponse = await dio.head(url);
      totalSize =
          int.tryParse(headResponse.headers.value('content-length') ?? '0') ??
          0;
      final acceptRanges = headResponse.headers.value('accept-ranges');
      supportsRange = acceptRanges == 'bytes' || totalSize > 0;
    } catch (e) {
      debugPrint('HEAD request failed, trying GET: $e');
      // Fallback: do a range request to check
      try {
        final headers = Map<String, dynamic>.from(
          DownloadService.defaultHeaders,
        );
        headers['Range'] = 'bytes=0-0';
        final rangeResponse = await dio.get(
          url,
          options: Options(headers: headers, responseType: ResponseType.bytes),
        );
        if (rangeResponse.statusCode == 206) {
          supportsRange = true;
          final contentRange = rangeResponse.headers.value('content-range');
          if (contentRange != null) {
            final match = RegExp(r'/(\d+)').firstMatch(contentRange);
            if (match != null) {
              totalSize = int.parse(match.group(1)!);
            }
          }
        }
      } catch (e2) {
        debugPrint('Range check also failed: $e2');
      }
    }

    debugPrint(
      '📊 File size: ${(totalSize / 1024 / 1024).toStringAsFixed(2)} MB, Range support: $supportsRange',
    );

    // If we can't do parallel download, fall back to single stream
    if (!supportsRange || totalSize < _minChunkSize * 2) {
      debugPrint('⚠️ Falling back to single-stream download');
      if (cancelToken?.isCancelled == true) {
        dio.close();
        return;
      }
      await _downloadSingleStream(
        dio,
        url,
        savePath,
        onProgress,
        totalSize,
        cancelToken,
      );
      dio.close();
      return;
    }

    // Deterministic temp directory based on savePath hash to support RESUME
    // Hash the save path to get a unique but stable folder name
    final pathHash = savePath.hashCode.toRadixString(16);
    final tempDir = p.join(p.dirname(savePath), '.temp_chunks_$pathHash');
    await Directory(tempDir).create(recursive: true);

    final adaptiveChunks = totalSize > 0
        ? max(2, min(chunks, (totalSize / (4 * 1024 * 1024)).ceil()))
        : chunks;

    // Calculate chunk sizes
    final chunkSize = (totalSize / adaptiveChunks).ceil();
    final List<_ChunkInfo> chunkInfos = [];

    for (int i = 0; i < adaptiveChunks; i++) {
      final start = i * chunkSize;
      final end = min((i + 1) * chunkSize - 1, totalSize - 1);
      if (start < totalSize) {
        chunkInfos.add(_ChunkInfo(i, start, end));
      }
    }

    debugPrint(
      '📦 Downloading ${chunkInfos.length} chunks of ~${(chunkSize / 1024 / 1024).toStringAsFixed(2)} MB each',
    );

    // Track progress for each chunk
    final chunkProgress = List<int>.filled(chunkInfos.length, 0);
    int lastReported = 0;

    void updateProgress() {
      final totalReceived = chunkProgress.reduce((a, b) => a + b);
      // Throttle progress updates but ensure final 100% is sent
      if (totalReceived - lastReported > 100000 || totalReceived == totalSize) {
        onProgress(totalReceived, totalSize);
        lastReported = totalReceived;
      }
    }

    try {
      // Download all chunks in parallel with cancellation support
      final dioCancelToken = CancelToken();
      final futures = chunkInfos.map((chunk) async {
        // Check cancellation before starting each chunk
        if (cancelToken?.isCancelled == true) {
          dioCancelToken.cancel('Download paused');
          return '';
        }

        final chunkPath = p.join(tempDir, 'chunk_${chunk.index}');
        final chunkFile = File(chunkPath);
        int initialBytes = 0;

        // CHECK FOR RESUME: If chunk exists, verify size
        if (await chunkFile.exists()) {
          final existingSize = await chunkFile.length();
          final expectedSize = chunk.end - chunk.start + 1;

          if (existingSize == expectedSize) {
            // Chunk already complete!
            debugPrint('✅ Chunk ${chunk.index} already complete, skipping');
            chunkProgress[chunk.index] = existingSize;
            updateProgress();
            return chunkPath;
          } else if (existingSize < expectedSize) {
            // Partial chunk found. Restart this chunk to avoid overwrite corruption.
            debugPrint(
              '🔄 Restarting partial chunk ${chunk.index} ($existingSize/$expectedSize)',
            );
            await chunkFile.delete();
            initialBytes = 0;
          } else {
            // Corrupt (larger than expected), restart chunk
            debugPrint('⚠️ Chunk ${chunk.index} corrupt, restarting');
            await chunkFile.delete();
            initialBytes = 0;
          }
        }

        // Only download if not complete
        final chunkHeaders = Map<String, dynamic>.from(
          DownloadService.defaultHeaders,
        );
        chunkHeaders['Range'] =
            'bytes=${chunk.start + initialBytes}-${chunk.end}';

        final chunkDio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(minutes: 10),
            headers: chunkHeaders,
          ),
        );

        try {
          // If resuming, update progress to include existing bytes
          chunkProgress[chunk.index] = initialBytes;
          updateProgress();

          await chunkDio.download(
            url,
            chunkPath, // Dio will overwrite if exists, but we want to APPEND
            cancelToken: dioCancelToken,
            deleteOnError: false, // Don't delete valuable partial data
            options: Options(
              // If initialBytes > 0, we need to append.
              // Standard dio.download doesn't support append easily.
              // Workaround: We'll use a temp file for the *remaining* part, then append manually?
              // Or better: Just download the *remainder* to a temp file, then append it?
              // Simpler for now: Dio's download overwrites.
              // Correct Approach: Use stream manually if appending.
              // FAST PATH: If fresh, use download. If resume, use stream.
            ),
            onReceiveProgress: (received, _) {
              if (cancelToken?.isCancelled == true &&
                  !dioCancelToken.isCancelled) {
                dioCancelToken.cancel('Download paused');
                return;
              }
              // Progress of *this request* + initial bytes
              chunkProgress[chunk.index] = initialBytes + received;
              updateProgress();
            },
          );
        } catch (e) {
          // Handle "Range Not Satisfiable" (416) if completed
          if (e is DioException && e.response?.statusCode == 416) {
            // Possibly already done?
          }
          rethrow;
        } finally {
          chunkDio.close();
        }

        return chunkPath;
      }).toList();

      final chunkPaths = await Future.wait(futures);

      // If cancelled, don't merge (keep temp files for resume!)
      if (cancelToken?.isCancelled == true) {
        debugPrint('⏸️ Download cancelled/paused, skipping merge');
        return;
      }

      // Merge chunks into final file
      debugPrint('🔗 Merging ${chunkPaths.length} chunks...');
      final outputFile = File(savePath);
      final sink = outputFile.openWrite();

      try {
        for (int i = 0; i < chunkPaths.length; i++) {
          final chunkFile = File(chunkPaths[i]);
          if (await chunkFile.exists()) {
            await sink.addStream(chunkFile.openRead());
          }
        }
      } finally {
        await sink.close();
      }
      debugPrint(
        '✅ Parallel download complete: ${(totalSize / 1024 / 1024).toStringAsFixed(2)} MB',
      );

      // Cleanup temp directory only on SUCCESS
      try {
        await Directory(tempDir).delete(recursive: true);
      } catch (e) {
        debugPrint('Warning: Failed to cleanup temp chunks: $e');
      }
    } catch (e) {
      // On error/cancel, do NOT delete temp dir so we can resume later
      if (cancelToken?.isCancelled != true) {
        // Only clean if it was a fatal error not a pause?
        // No, keep chunks even on error for retry.
      }
      dio.close();
      rethrow;
    }

    dio.close();
  }

  /// Fallback single-stream download
  Future<void> _downloadSingleStream(
    Dio dio,
    String url,
    String savePath,
    void Function(int received, int total) onProgress,
    int totalSize,
    BackendCancelToken? cancelToken,
  ) async {
    final dioCancelToken = CancelToken();
    await dio.download(
      url,
      savePath,
      cancelToken: dioCancelToken,
      onReceiveProgress: (received, total) {
        if (cancelToken?.isCancelled == true && !dioCancelToken.isCancelled) {
          dioCancelToken.cancel('Download paused');
          return;
        }
        onProgress(received, total > 0 ? total : totalSize);
      },
    );
  }

  /// Download DASH video + audio directly, then merge - using FAST parallel downloads
  Future<void> _downloadDashDirect(
    DownloadTask task,
    DirectUrls urls,
    String savePath,
    Dio dio,
    Function(DownloadTask)? onProgress,
    BackendCancelToken? cancelToken,
  ) async {
    final dir = p.dirname(savePath);

    // Ensure parent directory exists
    final downloadDir = Directory(dir);
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }

    final baseName = p.basenameWithoutExtension(savePath);

    // Determine file extensions based on format info from server
    final videoExt = urls.videoFormat?.toLowerCase().contains('webm') == true
        ? 'webm'
        : 'mp4';
    final audioExt = urls.audioFormat?.toLowerCase().contains('webm') == true
        ? 'webm'
        : 'm4a';

    final videoPath = p.join(dir, '${baseName}_video.$videoExt');
    final audioPath = p.join(dir, '${baseName}_audio.$audioExt');

    debugPrint('📥 FAST downloading video stream');
    debugPrint('📥 FAST downloading audio stream');

    int videoSize = 0;
    int audioSize = 0;

    // Download video with parallel chunks (0-50% progress)
    task.statusMessage = 'Downloading video...';
    onProgress?.call(task);

    try {
      await _downloadParallel(
        url: urls.videoUrl,
        savePath: videoPath,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          videoSize = total;
          if (total > 0) {
            task.progress = (received / total) * 0.45;
            task.downloadedBytes = received;
            task.totalBytes = total + (audioSize > 0 ? audioSize : total ~/ 3);
            onProgress?.call(task);
          }
        },
      );
      debugPrint(
        '✅ Video downloaded: ${File(videoPath).existsSync() ? "exists" : "MISSING!"}',
      );
    } catch (e) {
      debugPrint('❌ Video download failed: $e');
      // If cancelled via CancelToken, treat as pause not error
      if (cancelToken?.isCancelled == true) return;
      rethrow;
    }

    // Check cancellation after video download
    if (cancelToken?.isCancelled == true) {
      debugPrint('⏸️ Download paused after video download');
      return;
    }

    // Download audio with parallel chunks (50-90% progress)
    task.statusMessage = 'Downloading audio...';
    onProgress?.call(task);

    try {
      await _downloadParallel(
        url: urls.audioUrl!,
        savePath: audioPath,
        cancelToken: cancelToken,
        chunks: 4, // Fewer chunks for smaller audio file
        onProgress: (received, total) {
          audioSize = total;
          if (total > 0) {
            task.progress = 0.45 + (received / total) * 0.45;
            task.totalBytes = videoSize + total;
            task.downloadedBytes = videoSize + received;
            onProgress?.call(task);
          }
        },
      );
      debugPrint(
        '✅ Audio downloaded: ${File(audioPath).existsSync() ? "exists" : "MISSING!"}',
      );
    } catch (e) {
      debugPrint('❌ Audio download failed: $e');
      // If cancelled via CancelToken, treat as pause not error
      if (cancelToken?.isCancelled == true) return;
      // Cleanup video file
      try {
        await File(videoPath).delete();
      } catch (_) {}
      rethrow;
    }

    // Check cancellation before merge
    if (cancelToken?.isCancelled == true) {
      debugPrint('⏸️ Download paused before merge');
      return;
    }

    // Merge with FFmpeg (90-100% progress) with realtime progress
    task.statusMessage = 'Merging video & audio...';
    task.status = DownloadStatus.merging;
    task.progress = 0.9;
    onProgress?.call(task);

    final ffmpegService = FFmpegService();
    final success = await ffmpegService.mergeVideoAudio(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: savePath,
      onProgress: (p) {
        task.progress = 0.9 + (p * 0.1);
        onProgress?.call(task);
      },
    );

    // Note: FFmpegService.mergeVideoAudio already cleans up temp files on success

    if (!success) {
      // Cleanup temp files on merge failure (FFmpeg only cleans on success)
      try {
        if (await File(videoPath).exists()) await File(videoPath).delete();
        if (await File(audioPath).exists()) await File(audioPath).delete();
      } catch (e) {
        debugPrint('Warning: Failed to cleanup temp files: $e');
      }
      throw Exception('Failed to merge video and audio');
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    _dio.close();
  }
}

/// Video info from backend (Java server with NewPipe Extractor)
class BackendVideoInfo {
  final String? id;
  final String? title;
  final String? description;
  final int? duration;
  final String? thumbnail;
  final String? channel;
  final int? viewCount;
  final List<BackendFormat>? formats;
  final List<BackendFormat>? audioFormats;

  BackendVideoInfo({
    this.id,
    this.title,
    this.description,
    this.duration,
    this.thumbnail,
    this.channel,
    this.viewCount,
    this.formats,
    this.audioFormats,
  });

  factory BackendVideoInfo.fromJson(Map<String, dynamic> json) {
    return BackendVideoInfo(
      id: json['videoId'] ?? json['id'],
      title: json['title'],
      description: json['description'],
      duration: json['duration'],
      thumbnail: json['thumbnail'],
      channel: json['uploader'] ?? json['channel'],
      viewCount: json['view_count'],
      formats: (json['formats'] as List?)
          ?.map((f) => BackendFormat.fromJson(f))
          .toList(),
      audioFormats: (json['audioFormats'] as List?)
          ?.map((f) => BackendFormat.fromJson(f))
          .toList(),
    );
  }
}

/// Format info from backend (Java server with NewPipe Extractor)
class BackendFormat {
  final String? formatId;
  final String? ext;
  final String? format;
  final String? resolution;
  final int? height;
  final int? width;
  final int? fps;
  final String? vcodec;
  final String? acodec;
  final int? filesize;
  final int? bitrate;
  final double? tbr;
  final bool hasVideo;
  final bool hasAudio;
  final bool isVideoOnly;
  final String? url;

  BackendFormat({
    this.formatId,
    this.ext,
    this.format,
    this.resolution,
    this.height,
    this.width,
    this.fps,
    this.vcodec,
    this.acodec,
    this.filesize,
    this.bitrate,
    this.tbr,
    this.hasVideo = false,
    this.hasAudio = false,
    this.isVideoOnly = false,
    this.url,
  });

  factory BackendFormat.fromJson(Map<String, dynamic> json) {
    // Parse resolution like "1080p" to height
    int? parsedHeight = json['height'];
    final resolution = json['resolution'] as String?;
    if (parsedHeight == null && resolution != null) {
      final match = RegExp(r'(\d+)p').firstMatch(resolution);
      if (match != null) {
        parsedHeight = int.tryParse(match.group(1)!);
      }
    }

    return BackendFormat(
      formatId: json['format_id'] ?? json['itag']?.toString(),
      ext: json['ext'] ?? json['format']?.toString().toLowerCase(),
      format: json['format'],
      resolution: resolution,
      height: parsedHeight,
      width: json['width'],
      fps: json['fps'],
      vcodec: json['vcodec'],
      acodec: json['acodec'],
      filesize: json['filesize'],
      bitrate: json['bitrate'],
      tbr: json['tbr']?.toDouble(),
      hasVideo: json['has_video'] ?? (resolution != null),
      hasAudio: json['has_audio'] ?? !(json['isVideoOnly'] ?? false),
      isVideoOnly: json['isVideoOnly'] ?? false,
      url: json['url'],
    );
  }
}

/// Direct URLs response from backend (for FAST direct downloads)
class DirectUrls {
  final String videoId;
  final String title;
  final int duration;
  final bool needsMerge;
  final String videoUrl;
  final String? audioUrl;
  final String? videoFormat;
  final String? audioFormat;
  final String actualQuality;

  DirectUrls({
    required this.videoId,
    required this.title,
    required this.duration,
    required this.needsMerge,
    required this.videoUrl,
    this.audioUrl,
    this.videoFormat,
    this.audioFormat,
    required this.actualQuality,
  });

  factory DirectUrls.fromJson(Map<String, dynamic> json) {
    return DirectUrls(
      videoId: json['videoId'] ?? '',
      title: json['title'] ?? '',
      duration: json['duration'] ?? 0,
      needsMerge: json['needsMerge'] ?? false,
      videoUrl: json['videoUrl'] ?? '',
      audioUrl: json['audioUrl'],
      videoFormat: json['videoFormat'],
      audioFormat: json['audioFormat'],
      actualQuality: json['actualQuality'] ?? '',
    );
  }
}

/// Helper class for chunk information
class _ChunkInfo {
  final int index;
  final int start;
  final int end;

  _ChunkInfo(this.index, this.start, this.end);

  int get size => end - start + 1;
}
