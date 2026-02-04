import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/models.dart';
import 'ffmpeg_service.dart';
import 'youtube_service.dart';
import 'backend_download_service.dart';
import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

/// Service to manage file downloads with pause/resume support
class DownloadService {
  final Dio _dio = Dio();
  final FFmpegService _ffmpegService = FFmpegService();
  final YouTubeService _youtubeService = YouTubeService();
  final BackendDownloadService _backendService = BackendDownloadService();
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _pausedDownloads = {}; // Track paused state
  final Map<String, DetectedMedia> _downloadMedia = {}; // Store media for resume
  
  // Backend server settings
  bool _useBackendForDash = true; // Enable backend server for DASH downloads
  bool? _backendAvailable; // Cache backend availability

  // Download directory
  String? _downloadPath;

// Headers required for YouTube downloads
  static const Map<String, String> _defaultHeaders = {
    // Keep the Pixel 7 User-Agent
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
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
      final dir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory(p.join(dir.path, 'MediaTube'));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      _downloadPath = downloadDir.path;
    }

    return _downloadPath!;
  }

  /// Create a download task without starting the download
  Future<DownloadTask> createDownloadTask(DetectedMedia media) async {
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
      requiresMerge: media.isDash && media.audioUrl != null && !media.useBackend,
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
  
  /// Enable/disable backend for DASH downloads
  void setUseBackendForDash(bool use) {
    _useBackendForDash = use;
  }
  
  /// Get backend download service (for UI access)
  BackendDownloadService get backendService => _backendService;

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

    task.status = DownloadStatus.downloading;
    onProgress?.call(task);

    print('Starting download: ${media.title}');
    print('Source: ${media.source}, VideoId: ${media.videoId}');

    try {
      // ALWAYS use backend for YouTube videos
      if (media.source == MediaSource.youtube) {
        print('🌐 Using backend server for YouTube download');
        
        // Use backend service - it extracts URLs, app downloads directly from CDN
        await _backendService.downloadDirect(
          task,
          media,
          savePath: task.savePath,
          onProgress: onProgress,
          onComplete: onComplete,
          onError: onError,
        );
        return; // Backend handles completion/error callbacks
      }
      
      // Non-YouTube sources - direct download
      print('Using direct download for non-YouTube source');
      task = await _downloadSingleFileResumable(task, onProgress, cancelToken);

      // Check if paused
      if (_pausedDownloads[task.id] == true) {
        task.status = DownloadStatus.paused;
        onProgress?.call(task);
        return;
      }

      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      print('Download completed: ${media.title}');
      _cleanup(task.id);
      onComplete?.call(task);
    } catch (e, stackTrace) {
      print('Download error: $e');
      print('Stack trace: $stackTrace');
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
    _pausedDownloads.remove(taskId);
    _downloadMedia.remove(taskId);
  }

  /// Pause a download
  void pauseDownload(String taskId) {
    _pausedDownloads[taskId] = true;
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Paused');
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

  /// Download a media file (legacy method for compatibility)
  Future<DownloadTask> downloadMedia(
    DetectedMedia media, {
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
  }) async {
    final task = await createDownloadTask(media);
    await startDownload(task, media,
      onProgress: onProgress,
      onComplete: onComplete,
      onError: onError
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

    if (supportsRange && downloadedBytes > 0 && downloadedBytes < task.totalBytes) {
      // Resume download
      print('Resuming download from $downloadedBytes bytes');
      final headers = Map<String, String>.from(_defaultHeaders);
      headers['Range'] = 'bytes=$downloadedBytes-';

      await _dio.download(
        task.url,
        tempPath,
        cancelToken: cancelToken,
        options: Options(headers: headers),
        deleteOnError: false,
        onReceiveProgress: (received, total) {
          if (_pausedDownloads[task.id] == true) {
            cancelToken.cancel('Paused');
            return;
          }
          final totalReceived = downloadedBytes + received;
          task.downloadedBytes = totalReceived;
          if (task.totalBytes > 0) {
            task.progress = totalReceived / task.totalBytes;
            onProgress?.call(task);
          }
        },
      );
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

  Future<DownloadTask> _downloadDashMedia(
    DownloadTask task,
    DetectedMedia media,
    Function(DownloadTask)? onProgress,
  ) async {
    final basePath = await downloadPath;
    final tempVideoPath = p.join(basePath, '${task.id}_video.tmp');
    final tempAudioPath = p.join(basePath, '${task.id}_audio.tmp');

    final cancelToken = _cancelTokens[task.id]!;

    // Download video stream (50% of progress)
    await _dio.download(
      task.url,
      tempVideoPath,
      cancelToken: cancelToken,
      options: Options(headers: _defaultHeaders),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          task.progress = (received / total) * 0.4;
          onProgress?.call(task);
        }
      },
    );

    // Download audio stream (40% of progress)
    await _dio.download(
      task.audioUrl!,
      tempAudioPath,
      cancelToken: cancelToken,
      options: Options(headers: _defaultHeaders),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          task.progress = 0.4 + (received / total) * 0.4;
          onProgress?.call(task);
        }
      },
    );

    // Merge video and audio (20% of progress)
    task.status = DownloadStatus.merging;
    onProgress?.call(task);

    final mergeSuccess = await _ffmpegService.mergeVideoAudio(
      videoPath: tempVideoPath,
      audioPath: tempAudioPath,
      outputPath: task.savePath,
      onProgress: (progress) {
        task.progress = 0.8 + (progress * 0.2);
        onProgress?.call(task);
      },
    );

    if (!mergeSuccess) {
      // Clean up temp files
      await _deleteFile(tempVideoPath);
      await _deleteFile(tempAudioPath);
      throw Exception('Failed to merge video and audio');
    }

    return task;
  }

  /// Download YouTube muxed stream with FRESH URL
  /// Uses youtube_explode_dart library stream client for reliable downloads
  Future<DownloadTask> _downloadYouTubeStream(
      DownloadTask task,
      DetectedMedia media,
      Function(DownloadTask)? onProgress,
      ) async {
    print('🚀 Starting YouTube Muxed Stream Download');
    
    final videoId = media.videoId;
    if (videoId == null) {
      throw Exception('No video ID available for YouTube download');
    }
    
    // Get fresh stream manifest to avoid expired URLs
    print('🔄 Fetching fresh stream manifest...');
    final yt = YoutubeExplode();
    
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      
      // Find best muxed stream (video + audio combined)
      final muxedStreams = manifest.muxed.toList();
      if (muxedStreams.isEmpty) {
        throw Exception('No muxed streams available');
      }
      
      // Sort by resolution (highest first - muxed streams max out at 720p)
      muxedStreams.sort((a, b) {
        final aHeight = a.videoResolution.height;
        final bHeight = b.videoResolution.height;
        return bHeight.compareTo(aHeight); // Higher resolution first
      });
      
      final selectedStream = muxedStreams.first;
      final qualityLabel = '${selectedStream.videoResolution.height}p';
      final totalBytes = selectedStream.size.totalBytes;
      
      print('📦 Selected: $qualityLabel (${totalBytes ~/ 1024 ~/ 1024}MB)');
      print('📥 Starting download to: ${task.savePath}');
      
      // Download using library stream client (handles auth/403 internally)
      final file = File(task.savePath);
      if (await file.exists()) {
        await file.delete();
      }
      
      final output = file.openWrite();
      final stream = yt.videos.streamsClient.get(selectedStream);
      
      int receivedBytes = 0;
      int lastLoggedPercent = -1;
      task.totalBytes = totalBytes;
      
      try {
        await for (final chunk in stream.timeout(const Duration(minutes: 30))) {
          // Check for cancellation
          if (_cancelTokens[task.id]?.isCancelled == true) {
            throw Exception('Download cancelled');
          }
          
          output.add(chunk);
          receivedBytes += chunk.length;
          
          task.downloadedBytes = receivedBytes;
          if (totalBytes > 0) {
            task.progress = receivedBytes / totalBytes;
            onProgress?.call(task);
            
            // Log progress every 10%
            final currentPercent = (task.progress * 100).toInt();
            if (currentPercent ~/ 10 > lastLoggedPercent ~/ 10) {
              lastLoggedPercent = currentPercent;
              print('📊 Progress: $currentPercent% (${receivedBytes ~/ 1024 ~/ 1024}MB / ${totalBytes ~/ 1024 ~/ 1024}MB)');
            }
          }
        }
        
        await output.flush();
        
        // Verify file size
        final savedFile = File(task.savePath);
        final savedSize = await savedFile.length();
        print('✅ Download complete: ${savedSize ~/ 1024 ~/ 1024}MB saved to ${task.savePath}');
        
        if (savedSize < 1000) {
          throw Exception('Downloaded file is too small ($savedSize bytes), likely corrupted');
        }
        
      } finally {
        await output.close();
      }
      
      return task;
      
    } catch (e) {
      print('❌ YouTube download error: $e');
      rethrow;
    } finally {
      yt.close();
    }
  }

  /// Extract itag parameter from YouTube stream URL
  String? _extractItag(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.queryParameters['itag'];
    } catch (e) {
      return null;
    }
  }


  /// Download YouTube DASH streams (separate video + audio) and merge
  /// Uses youtube_explode for reliable downloads with fresh URLs
  /// Enhanced YouTube DASH download with better evasion tactics
  Future<DownloadTask> _downloadYouTubeDashMedia(
      DownloadTask task,
      DetectedMedia media,
      Function(DownloadTask)? onProgress,
      ) async {
    final basePath = await downloadPath;
    final tempVideoPath = p.join(basePath, '${task.id}_video.tmp');
    final tempAudioPath = p.join(basePath, '${task.id}_audio.tmp');
    final cancelToken = _cancelTokens[task.id]!;

    print('🚀 Starting Enhanced YouTube Download...');

    try {
      // 1. GET MANIFEST WITH COOKIES
      String? cookieHeader;
      try {
        final cookies = await CookieManager.instance().getCookies(url: WebUri("https://www.youtube.com"));
        if (cookies.isNotEmpty) {
          cookieHeader = cookies.map((c) => "${c.name}=${c.value}").join("; ");
          print('🍪 Found ${cookies.length} cookies');
        }
      } catch (e) {
        print('⚠️ Cookie error: $e');
      }

      // 2. CREATE FRESH YOUTUBE CLIENT WITH PROPER CONFIGURATION
      Future<StreamManifest> fetchFreshManifest() async {
        final yt = YoutubeExplode();
        try {
          return await yt.videos.streamsClient.getManifest(media.videoId!);
        } finally {
          yt.close();
        }
      }

      // 3. GET INITIAL MANIFEST AND SELECT STREAMS
      final manifest = await fetchFreshManifest();

      // Select video stream - prefer DASH for high quality
      StreamInfo? videoStream;
      StreamInfo? audioStream;

      // For DASH download, we want high-quality video-only streams
      // Get the target quality from media if specified, otherwise use highest available
      final targetQuality = media.quality; // e.g., "1080p", "720p"
      int? targetHeight;
      if (targetQuality != null) {
        targetHeight = _parseResolution(targetQuality);
        print('🎯 Target quality: $targetQuality ($targetHeight p)');
      }

      // Select DASH video stream (prefer H.264/AVC for compatibility)
      final videoOnlyStreams = manifest.videoOnly.toList();
      if (videoOnlyStreams.isEmpty) {
        // Fallback to muxed if no video-only streams
        print('⚠️ No video-only streams, falling back to muxed');
        final muxedStreams = manifest.muxed.toList();
        if (muxedStreams.isEmpty) {
          throw Exception('No video streams available');
        }
        // Sort muxed by resolution (highest first)
        muxedStreams.sort((a, b) {
          final aRes = _parseResolution(_getQualityLabel(a));
          final bRes = _parseResolution(_getQualityLabel(b));
          return bRes.compareTo(aRes); // Higher resolution first
        });
        videoStream = muxedStreams.first;
        print('📺 Using muxed stream: ${_getQualityLabel(videoStream)}');
        
        // Download single muxed file
        await _downloadYouTubeStreamMuxed(
          videoStream,
          task,
          onProgress,
          cookieHeader: cookieHeader,
        );
        return task;
      }

      StreamInfo? selectedVideoStream;

      // Try to find H.264 streams first (better compatibility)
      final h264Streams = videoOnlyStreams.where((s) {
        final codec = _getVideoCodec(s);
        return codec.contains('avc') || codec.contains('h264');
      }).toList();

      final streamsToUse = h264Streams.isNotEmpty ? h264Streams : videoOnlyStreams;
      
      // Sort by resolution (highest first)
      streamsToUse.sort((a, b) {
        final aRes = _parseResolution(_getQualityLabel(a));
        final bRes = _parseResolution(_getQualityLabel(b));
        return bRes.compareTo(aRes); // Higher resolution first
      });

      // If target quality specified, find matching or closest lower
      if (targetHeight != null && targetHeight > 0) {
        selectedVideoStream = streamsToUse.firstWhere(
          (s) => _parseResolution(_getQualityLabel(s)) <= targetHeight!,
          orElse: () => streamsToUse.last, // Use lowest if none match
        );
      } else {
        // Use highest available
        selectedVideoStream = streamsToUse.first;
      }

      videoStream = selectedVideoStream;

      // Select audio stream (highest bitrate)
      final audioOnlyStreams = manifest.audioOnly.toList();
      if (audioOnlyStreams.isNotEmpty) {
        // Sort by bitrate (higher first)
        audioOnlyStreams.sort((a, b) {
          return _getBitrate(b).compareTo(_getBitrate(a));
        });
        audioStream = audioOnlyStreams.first;
      } else {
        throw Exception('No audio stream found');
      }

      print('🎥 Video: ${_getQualityLabel(videoStream)}, ${_getSizeInMB(videoStream)}');
      print('🔊 Audio: ${_getSizeInMB(audioStream)}');

      // 4. DOWNLOAD WITH IMPROVED EVASION
      final random = Random();

      Future<StreamInfo> getFreshStreamInfo(StreamInfo originalStream) async {
        print('♻️ Refreshing manifest for ${originalStream.tag}...');

        // 1. Get fresh manifest
        final yt = YoutubeExplode();
        try {
          final newManifest = await yt.videos.streamsClient.getManifest(media.videoId!);

          // 2. Find the exact same stream again using Itag
          final originalItag = _extractItag(originalStream.url.toString());
          final newStream = _findStreamByItag(newManifest, originalItag);

          if (newStream != null) {
            print('✅ Refreshed URL obtained');
            return newStream;
          }
          throw Exception('Stream with itag $originalItag not found in new manifest');
        } finally {
          yt.close();
        }
      }

      // Download video with improved evasion
      await _downloadWithEvasion(
        streamInfo: videoStream,
        savePath: tempVideoPath,
        task: task,
        label: 'Video',
        startProgress: 0.0,
        endProgress: 0.5,
        cookieHeader: cookieHeader,
        onProgress: onProgress,
        refreshUrl: () async => (await getFreshStreamInfo(videoStream!)).url.toString(),
        refreshStream: () => getFreshStreamInfo(videoStream!),
      );

      // Download audio
      await _downloadWithEvasion(
        streamInfo: audioStream,
        savePath: tempAudioPath,
        task: task,
        label: 'Audio',
        startProgress: 0.5,
        endProgress: 0.9,
        cookieHeader: cookieHeader,
        onProgress: onProgress,
        refreshUrl: () async => (await getFreshStreamInfo(audioStream!)).url.toString(),
        refreshStream: () => getFreshStreamInfo(audioStream!),
      );

      // 5. MERGE FILES
      task.status = DownloadStatus.merging;
      onProgress?.call(task);

      print('🔨 Merging video and audio...');
      final mergeSuccess = await _ffmpegService.mergeVideoAudio(
        videoPath: tempVideoPath,
        audioPath: tempAudioPath,
        outputPath: task.savePath,
        onProgress: (p) {
          task.progress = 0.9 + (p * 0.1);
          onProgress?.call(task);
        },
      );

      // Cleanup temp files
      await _deleteFile(tempVideoPath);
      await _deleteFile(tempAudioPath);

      if (!mergeSuccess) {
        throw Exception('Failed to merge video and audio');
      }

      print('✅ Download completed successfully!');
      return task;

    } catch (e, stackTrace) {
      print('❌ Download failed: $e');
      print(stackTrace);

      // Cleanup on failure
      await _deleteFile(tempVideoPath);
      await _deleteFile(tempAudioPath);

      rethrow;
    }
  }

  /// Parse resolution from quality label (e.g., "720p" -> 720)
  int _parseResolution(String qualityLabel) {
    try {
      final match = RegExp(r'(\d+)p').firstMatch(qualityLabel);
      if (match != null) {
        return int.parse(match.group(1)!);
      }
    } catch (e) {
      print('Error parsing resolution: $e');
    }
    return 0;
  }

  /// Download muxed stream (simpler, less likely to be blocked)
  Future<void> _downloadYouTubeStreamMuxed(
      StreamInfo streamInfo,
      DownloadTask task,
      Function(DownloadTask)? onProgress, {
        String? cookieHeader,
      }) async {
    final url = streamInfo.url.toString();
    final qualityLabel = _getQualityLabel(streamInfo);
    print('📦 Downloading muxed stream: $qualityLabel');

    // Get total bytes if available
    final totalBytes = _getTotalBytes(streamInfo);
    if (totalBytes > 0) {
      print('📊 File size: ${totalBytes ~/ 1024 ~/ 1024}MB');
    }

    // Use Dio with enhanced headers
    final headers = Map<String, String>.from(_defaultHeaders);

    // Clean headers for CDN (no cookies on googlevideo.com)
    if (url.contains('googlevideo.com')) {
      headers.remove('Cookie');
      headers.remove('Referer');
      headers.remove('Origin');

      // Add CDN-specific headers
      headers['Accept-Encoding'] = 'identity';
      headers['Connection'] = 'close';
    }

    // Use Dio with extended timeout
    await _dio.download(
      url,
      task.savePath,
      cancelToken: _cancelTokens[task.id],
      options: Options(
        headers: headers,
        receiveTimeout: const Duration(minutes: 30),
        followRedirects: true,
        validateStatus: (status) => status != null && status < 500,
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          task.progress = received / total;
          task.downloadedBytes = received;
          task.totalBytes = total;
          onProgress?.call(task);
        } else if (totalBytes > 0) {
          // Use estimated total if available
          task.progress = received / totalBytes;
          task.downloadedBytes = received;
          task.totalBytes = totalBytes;
          onProgress?.call(task);
        }
      },
    );
  }

  /// Enhanced download with evasion tactics
  Future<void> _downloadWithEvasion({
    required StreamInfo streamInfo,
    required String savePath,
    required DownloadTask task,
    required String label,
    required double startProgress,
    required double endProgress,
    String? cookieHeader,
    Function(DownloadTask)? onProgress,
    required Future<String> Function() refreshUrl,
    Future<StreamInfo> Function()? refreshStream,
  }) async {
    final qualityLabel = _getQualityLabel(streamInfo);
    print('🎬 Starting $label download ($qualityLabel) with evasion tactics...');

    final url = streamInfo.url.toString();
    final totalBytes = _getTotalBytes(streamInfo);
    final random = Random();

    if (totalBytes > 0) {
      print('📊 Total size: ${totalBytes ~/ 1024 ~/ 1024}MB');
    }

    // Choose download method based on URL pattern
    if (url.contains('googlevideo.com')) {
      // Use enhanced chunked download for CDN, fallback to library stream on persistent 403s
      try {
        await _enhancedChunkedDownload(
          url: url,
          savePath: savePath,
          totalBytes: totalBytes,
          task: task,
          label: label,
          startProgress: startProgress,
          endProgress: endProgress,
          onProgress: onProgress,
          refreshUrl: refreshUrl,
        );
      } catch (e) {
        print('⚠️ $label chunked download failed. Falling back to library stream...');
        final fallbackStreamInfo = refreshStream != null ? await refreshStream() : streamInfo;
        await _downloadFromLibraryStream(
          streamInfo: fallbackStreamInfo,
          savePath: savePath,
          label: label,
          startProgress: startProgress,
          endProgress: endProgress,
          task: task,
          onProgress: onProgress,
        );
      }
    } else {
      // Use standard download for other URLs
      await _downloadRawUrl(
        url: url,
        savePath: savePath,
        cancelToken: _cancelTokens[task.id]!,
        label: label,
        startProgress: startProgress,
        endProgress: endProgress,
        task: task,
        onProgress: onProgress,
      );
    }
  }

// ========== SAFE PROPERTY ACCESS HELPER METHODS ==========

  /// Get total bytes from stream info safely
  int _getTotalBytes(StreamInfo stream) {
    try {
      // Try different possible property names
      if (stream is VideoOnlyStreamInfo) {
        return stream.size.totalBytes;
      } else if (stream is AudioOnlyStreamInfo) {
        return stream.size.totalBytes;
      } else if (stream is MuxedStreamInfo) {
        return stream.size.totalBytes;
      }

      // Fallback: check for any size property
      final dynamicSize = (stream as dynamic).size;
      if (dynamicSize != null) {
        final dynamicTotal = (dynamicSize as dynamic).totalBytes;
        if (dynamicTotal is int) return dynamicTotal;
      }
    } catch (e) {
      print('Error getting total bytes: $e');
    }
    return 0;
  }

  /// Get bitrate from stream info safely
  int _getBitrate(StreamInfo stream) {
    try {
      if (stream is AudioOnlyStreamInfo) {
        return stream.bitrate.bitsPerSecond;
      }

      // Fallback
      final dynamicBitrate = (stream as dynamic).bitrate;
      if (dynamicBitrate != null) {
        final dynamicBits = (dynamicBitrate as dynamic).bitsPerSecond;
        if (dynamicBits is int) return dynamicBits;
      }
    } catch (e) {
      print('Error getting bitrate: $e');
    }
    return 0;
  }

  /// Get video codec from stream info safely
  String _getVideoCodec(StreamInfo stream) {
    try {
      if (stream is VideoOnlyStreamInfo) {
        return stream.videoCodec.toLowerCase();
      } else if (stream is MuxedStreamInfo) {
        return stream.videoCodec.toLowerCase();
      }

      // Fallback
      final dynamicCodec = (stream as dynamic).videoCodec;
      if (dynamicCodec is String) return dynamicCodec.toLowerCase();
    } catch (e) {
      print('Error getting video codec: $e');
    }
    return '';
  }

  /// Get quality label from stream info safely
  String _getQualityLabel(StreamInfo stream) {
    try {
      if (stream is VideoStreamInfo) {
        // The API likely changed to .qualityLabel or .videoQuality.label
        // Use toString() as a safe fallback if specific properties fail
        return stream.videoQuality.toString();
      }
      if (stream is AudioOnlyStreamInfo) {
        return 'Audio (${_getBitrate(stream) ~/ 1000} kbps)';
      }
    } catch (e) {
      // Silent fail
    }
    return 'Unknown';
  }

  /// Helper to get stream size in MB for logging
  String _getSizeInMB(StreamInfo stream) {
    final bytes = _getTotalBytes(stream);
    if (bytes == 0) return 'Unknown size';
    return '${bytes ~/ 1024 ~/ 1024}MB';
  }

  /// Helper to check if stream is H.264
  bool _isH264(StreamInfo stream) {
    final codec = _getVideoCodec(stream);
    return codec.contains('avc') || codec.contains('h264');
  }

  /// Find stream by itag (used in other parts of your code)
  StreamInfo? _findStreamByItag(StreamManifest manifest, String? itag) {
    if (itag == null) return null;

    try {
      final allStreams = [
        ...manifest.videoOnly,
        ...manifest.audioOnly,
        ...manifest.muxed,
      ];

      for (final stream in allStreams) {
        final uri = Uri.parse(stream.url.toString());
        final streamItag = uri.queryParameters['itag'];
        if (streamItag == itag) {
          return stream;
        }
      }
    } catch (e) {
      print('Error finding stream by itag: $e');
    }

    return null;
  }




  /// Enhanced chunked download with Auto-Refresh for 403s
  Future<void> _enhancedChunkedDownload({
    required String url,
    required String savePath,
    required int totalBytes,
    required DownloadTask task,
    required String label,
    required double startProgress,
    required double endProgress,
    required Future<String> Function() refreshUrl,
    Function(DownloadTask)? onProgress,
  }) async {
    final file = File(savePath);
    IOSink sink;
    int downloaded = 0;

    // Resume logic
    if (await file.exists()) {
      downloaded = await file.length();
      if (downloaded >= totalBytes) return;
      sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    } else {
      sink = file.openWrite();
    }

    String currentUrl = url;
    int failures = 0;
    int consecutive403 = 0;
    const int max403Refreshes = 5;
    const int maxFailures = 5;
    const int chunkSize = 2 * 1024 * 1024; // 2MB chunks

    try {
      while (downloaded < totalBytes) {
        if (failures >= maxFailures) throw Exception('Too many failures');

        if (_cancelTokens[task.id]?.isCancelled == true) {
          throw Exception('Cancelled');
        }

        int end = downloaded + chunkSize;
        if (end > totalBytes) end = totalBytes;

        // Include User-Agent to match the signed URL client params
        final headers = {
          'Range': 'bytes=$downloaded-${end - 1}',
          'Accept': '*/*',
          'Connection': 'keep-alive',
          'Accept-Encoding': 'identity',
          if (_defaultHeaders['User-Agent'] != null) 'User-Agent': _defaultHeaders['User-Agent']!,
        };

        try {
          final response = await http.get(
            Uri.parse(currentUrl),
            headers: headers,
          ).timeout(const Duration(seconds: 30));

          if (response.statusCode == 200 || response.statusCode == 206) {
            final bytes = response.bodyBytes;
            sink.add(bytes);
            await sink.flush();

            downloaded += bytes.length;
            failures = 0;
            consecutive403 = 0;

            // Update Progress
            if (totalBytes > 0) {
              final sectionProgress = downloaded / totalBytes;
              final currentTotal = startProgress + (sectionProgress * (endProgress - startProgress));
              task.progress = currentTotal;
              onProgress?.call(task);
            }

          } else if (response.statusCode == 403) {
            print('🔄 $label URL expired (403). Refreshing signature...');
            consecutive403++;
            if (consecutive403 >= max403Refreshes) {
              throw Exception('Too many 403 refreshes for $label');
            }
            try {
              currentUrl = await refreshUrl();
              failures = 0;
              // Do NOT increment failure count on a successful refresh
              await Future.delayed(const Duration(milliseconds: 300));
              continue;
            } catch (e) {
              print('❌ Failed to refresh URL: $e');
              failures++;
            }
          } else {
            failures++;
            print('HTTP Error ${response.statusCode}');
          }
        } catch (e) {
          failures++;
          print('Chunk Error: $e');
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }



  /// Helper to get stream size in MB for logging
  String _getSizeInMBString(StreamInfo stream) {
    final bytes = _getTotalBytes(stream);
    if (bytes == 0) return 'Unknown size';
    return '${bytes ~/ 1024 ~/ 1024}MB';
  }

  /// Helper to check if stream is H.264
  bool _isStreamH264(StreamInfo stream) {
    final codec = _getVideoCodec(stream);
    return codec.contains('avc') || codec.contains('h264');
  }



  /// Cancel a download
  void cancelDownload(String taskId) {
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Download cancelled by user');
    }
  }

  /// Cancel all downloads
  void cancelAllDownloads() {
    for (final token in _cancelTokens.values) {
      if (!token.isCancelled) {
        token.cancel('All downloads cancelled');
      }
    }
    _cancelTokens.clear();
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
      print('Error deleting file: $e');
    }
    return false;
  }

  String _sanitizeFileName(String name) {
    // Remove invalid characters for file names on Windows/Android
    // Including: < > : " / \ | ? * and control characters
    var sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')  // Replace invalid chars with underscore
        .replaceAll(RegExp(r'[\s]+'), '_')  // Replace whitespace with underscore
        .replaceAll(RegExp(r'_+'), '_')  // Collapse multiple underscores
        .replaceAll(RegExp(r'^_+|_+$'), '');  // Trim leading/trailing underscores
    
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

  /// Helper: Powerful Dio Downloader with Retry, Timeout & Custom Headers
  Future<void> _downloadRawUrl({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    required String label,
    required double startProgress,
    required double endProgress,
    required DownloadTask task,
    // NEW: Allow passing custom headers (Cookies)
    Map<String, String>? customHeaders,
    Function(DownloadTask)? onProgress,
  }) async {
    int retryCount = 0;
    const maxRetries = 3;

    // Merge custom headers with default ones
    final effectiveHeaders = Map<String, String>.from(_defaultHeaders);
    if (customHeaders != null) {
      effectiveHeaders.addAll(customHeaders);
    }

    while (retryCount < maxRetries) {
      try {
        print('📥 Downloading $label (Attempt ${retryCount + 1})...');

        await _dio.download(
          url,
          savePath,
          cancelToken: cancelToken,
          deleteOnError: false,
          options: Options(
            headers: effectiveHeaders, // USE THE MERGED HEADERS
            receiveTimeout: const Duration(minutes: 30),
          ),
          onReceiveProgress: (received, total) {
            if (total != -1) {
              final sectionProgress = received / total;
              final currentTotal = startProgress + (sectionProgress * (endProgress - startProgress));
              task.progress = currentTotal;
              onProgress?.call(task);
            }
          },
        );
        return; // Success!
      } catch (e) {
        print('⚠️ $label Download Error: $e');
        retryCount++;

        if (cancelToken.isCancelled) rethrow;

        // If 403, it means cookies/url expired.
        if (e.toString().contains('403') && retryCount >= maxRetries) {
          throw Exception('Access Denied (403). The link expired or was blocked.');
        }

        if (retryCount >= maxRetries) rethrow;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Helper: Downloads from Library Stream with 30-MINUTE Timeout
  Future<void> _downloadFromLibraryStream({
    required StreamInfo streamInfo,
    required String savePath,
    required String label,
    required double startProgress,
    required double endProgress,
    required DownloadTask task,
    Function(DownloadTask)? onProgress,
  }) async {
    print('📥 Downloading $label via Native Stream (Itag: ${_extractItag(streamInfo.url.toString())})...');

    final file = File(savePath);
    if (await file.exists()) await file.delete();

    final output = file.openWrite();
    // Use the library's internal client (Handles Auth/403)
    final stream = _youtubeService.yt.videos.streamsClient.get(streamInfo);

    final totalBytes = streamInfo.size.totalBytes;
    var receivedBytes = 0;

    try {
      // FIX: Set timeout to 30 MINUTES (previously was 60s)
      // This resets every time a byte is received, so it only triggers if connection dies completely
      await for (final chunk in stream.timeout(const Duration(minutes: 30))) {
        output.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes > 0) {
          final sectionProgress = receivedBytes / totalBytes;
          final currentTotal = startProgress + (sectionProgress * (endProgress - startProgress));
          task.progress = currentTotal;
          onProgress?.call(task);
        }

        // Check cancellation
        if (_cancelTokens[task.id]?.isCancelled == true) {
          throw Exception('Cancelled');
        }
      }
    } catch (e) {
      print('Stream Error ($label): $e');
      rethrow;
    } finally {
      await output.flush();
      await output.close();
    }
  }


  /// Helper: Writes a Library Stream directly to disk (Bypasses 403s)
  Future<void> _downloadStreamToDisk({
    required YoutubeExplode yt,
    required StreamInfo streamInfo,
    required String savePath,
    required String label,
    required double startProgress,
    required double endProgress,
    required DownloadTask task,
    Function(DownloadTask)? onProgress,
  }) async {
    print('📥 Downloading $label (Internal Stream)...');

    final file = File(savePath);
    if (await file.exists()) await file.delete();

    final output = file.openWrite();
    // Get stream from the authenticated YT instance
    final stream = yt.videos.streamsClient.get(streamInfo);

    final totalBytes = streamInfo.size.totalBytes;
    var receivedBytes = 0;
    int lastPercent = 0;

    try {
      // 30 Minute Timeout to prevent "Hanging"
      await for (final chunk in stream.timeout(const Duration(minutes: 30))) {
        output.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes > 0) {
          final sectionProgress = receivedBytes / totalBytes;
          final currentTotal = startProgress + (sectionProgress * (endProgress - startProgress));
          task.progress = currentTotal;
          onProgress?.call(task);

          // Log occasionally to prove it's alive
          final percent = (sectionProgress * 100).toInt();
          if (percent > lastPercent + 10) {
            print('$label Progress: $percent%');
            lastPercent = percent;
          }
        }

        if (_cancelTokens[task.id]?.isCancelled == true) {
          throw Exception('Cancelled');
        }
      }
    } catch (e) {
      print('Stream Error ($label): $e');
      rethrow;
    } finally {
      await output.flush();
      await output.close();
    }
  }
  /// FIXED: Robust Chunked Downloader with Auto-Refresh for Expired URLs
  Future<void> _downloadSignedUrlChunked({
    required String url,
    required String savePath,
    required int totalBytes,
    required String label,
    required double startProgress,
    required double endProgress,
    required DownloadTask task,
    required Future<String> Function() onUrlExpired, // NEW: Refresh callback
    Function(DownloadTask)? onProgress,
  }) async {
    print('📥 Downloading $label (Chunked)... Total: ${(totalBytes/1024/1024).toStringAsFixed(2)} MB');

    final file = File(savePath);
    // Only delete if starting fresh; otherwise we append/resume
    if (await file.exists() && await file.length() > totalBytes) {
      await file.delete();
    }

    // Open in append mode to support resuming
    var sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    var currentFileLength = await file.exists() ? await file.length() : 0;

    // If file is corrupted or larger than target, reset
    if (currentFileLength > totalBytes) {
      await sink.close();
      await file.delete();
      sink = file.openWrite();
      currentFileLength = 0;
    }

    int downloaded = currentFileLength;
    String currentUrl = url;

    // 2MB Chunks (Optimal for YouTube throttling)
    const int chunkSize = 4 * 1024 * 1024;
    int retryCount = 0;
    const int maxRetries = 10; // Increased retries

    try {
      while (downloaded < totalBytes) {
        if (_cancelTokens[task.id]?.isCancelled == true) throw Exception('Cancelled');

        int end = downloaded + chunkSize;
        if (end > totalBytes) end = totalBytes;

        final headers = {'Range': 'bytes=$downloaded-${end - 1}'};

        try {
          final response = await http.get(Uri.parse(currentUrl), headers: headers)
              .timeout(const Duration(seconds: 45));

          if (response.statusCode == 200 || response.statusCode == 206) {
            sink.add(response.bodyBytes);
            // Flush periodically to save RAM
            await sink.flush();

            downloaded += response.bodyBytes.length;
            retryCount = 0;

            final sectionProgress = downloaded / totalBytes;
            final currentTotal = startProgress + (sectionProgress * (endProgress - startProgress));
            task.progress = currentTotal;
            onProgress?.call(task);

            // Log occasionally
            if (downloaded % (chunkSize * 10) == 0) {
              print('$label: ${(sectionProgress * 100).toStringAsFixed(0)}%');
            }
          } else if (response.statusCode == 403) {
            // URL EXPIRED: REFRESH IT
            print('🔄 $label URL expired (403). Refreshing...');
            currentUrl = await onUrlExpired();
            retryCount++;
            if (retryCount > maxRetries) throw Exception('Max Retries (403) Exceeded');
            continue; // Retry chunk with new URL
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
        } catch (e) {
          print('⚠️ Chunk Error ($downloaded-$end): $e');
          retryCount++;

          if (retryCount >= maxRetries) throw Exception('Max Retries Exceeded');

          // If generic error, try refreshing URL too, just in case
          if (retryCount > 2) {
            print('🔄 Persistent error. Trying URL refresh...');
            try { currentUrl = await onUrlExpired(); } catch (_) {}
          }

          await Future.delayed(const Duration(seconds: 2));
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }
}

/// A custom HTTP client that manages headers for YouTube requests
class CookieClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final String cookies;
  final String userAgent;

  CookieClient({required this.cookies, required this.userAgent});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // 1. ALWAYS set User-Agent (Required for both API and CDN)
    request.headers['User-Agent'] = userAgent;

    final host = request.url.host;

    // 2. LOGIC SPLIT:
    // API (youtube.com): NEEDS Auth (Cookies, Referer, Origin)
    // CDN (googlevideo.com): HATES Auth (Must be clean)
    if (host.endsWith('youtube.com') || host.endsWith('youtu.be')) {
      request.headers['Cookie'] = cookies;
      request.headers['Referer'] = 'https://www.youtube.com/';
      request.headers['Origin'] = 'https://www.youtube.com';
    } else {
      // CLEAN REQUEST for Video Files
      // Removing these prevents the "Hotlinking" 403 error
      request.headers.remove('Cookie');
      request.headers.remove('Referer');
      request.headers.remove('Origin');
    }

    return _inner.send(request);
  }
}