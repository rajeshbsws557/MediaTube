import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/detected_media.dart';

/// Service to extract video/audio streams from YouTube using youtube_explode_dart
/// Optimized with caching and parallel operations
class YouTubeService {
  YoutubeExplode? _yt;
  static String? _visitorData;
  static String? _poToken;
  static const int _maxRetries = 3; // Allow more retries for network issues
  
  // Cache for manifests and video info to avoid repeated fetches
  final Map<String, _CachedData<StreamManifest>> _manifestCache = {};
  final Map<String, _CachedData<Video>> _videoCache = {};
  static const Duration _cacheDuration = Duration(minutes: 5);
  
  // Track last successful fetch time to avoid rapid retries
  DateTime? _lastFetchTime;

  YoutubeExplode get yt {
    _yt ??= YoutubeExplode();
    return _yt!;
  }

  /// Reinitialize the client (useful after errors)
  void _reinitializeClient() {
    try {
      _yt?.close();
    } catch (_) {}
    _yt = null; // Force recreation on next access
  }

  /// Set visitor data and PO token from WebView cookies
  static void setVisitorData(String? visitorData, String? poToken) {
    _visitorData = visitorData;
    _poToken = poToken;
  }

  /// Extract video ID from YouTube URL
  String? extractVideoId(String url) {
    try {
      return VideoId.parseVideoId(url);
    } catch (_) {
      return null;
    }
  }

  /// Check if URL is a valid YouTube video URL
  bool isValidYouTubeUrl(String url) {
    return extractVideoId(url) != null;
  }

  /// Get video metadata with caching
  Future<Video?> getVideoInfo(String url) async {
    try {
      final videoId = extractVideoId(url);
      if (videoId == null) return null;
      
      // Check cache first
      final cached = _videoCache[videoId];
      if (cached != null && !cached.isExpired) {
        return cached.data;
      }
      
      final video = await _executeWithRetry(() => yt.videos.get(videoId));
      _videoCache[videoId] = _CachedData(video);
      return video;
    } catch (e) {
      print('Error getting video info: $e');
      return null;
    }
  }

  /// Execute a function with retry logic for bot detection and timeout errors
  Future<T> _executeWithRetry<T>(Future<T> Function() fn, {int maxAttempts = 3}) async {
    Exception? lastError;
    
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // No external timeout - let the library handle its own timeout
        // youtube_explode_dart has 20s internal timeout
        return await fn();
      } on TimeoutException catch (e) {
        lastError = e;
        print('Attempt $attempt/$maxAttempts: Timeout');
        if (attempt < maxAttempts) {
          await _waitAndReinit(attempt);
        }
      } on SocketException catch (e) {
        lastError = e;
        print('Attempt $attempt/$maxAttempts: Network error');
        if (attempt < maxAttempts) {
          await _waitAndReinit(attempt);
        }
      } on HttpException catch (e) {
        lastError = e;
        print('Attempt $attempt/$maxAttempts: HTTP error');
        if (attempt < maxAttempts) {
          await _waitAndReinit(attempt);
        }
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        final errorMsg = e.toString().toLowerCase();
        
        // Check if error is retryable
        final isRetryable = errorMsg.contains('bot') || 
            errorMsg.contains('unplayable') ||
            errorMsg.contains('sign in') ||
            errorMsg.contains('429') ||
            errorMsg.contains('timeout') ||
            errorMsg.contains('socket') ||
            errorMsg.contains('connection') ||
            errorMsg.contains('failed host lookup');
        
        if (isRetryable && attempt < maxAttempts) {
          print('Attempt $attempt/$maxAttempts: ${e.runtimeType}');
          await _waitAndReinit(attempt);
        } else {
          throw lastError;
        }
      }
    }
    throw lastError ?? Exception('Max retries exceeded');
  }
  
  /// Wait with exponential backoff and reinitialize client
  Future<void> _waitAndReinit(int attempt) async {
    // Exponential backoff: 1s, 2s, 4s...
    final waitMs = 1000 * pow(2, attempt - 1).toInt();
    print('Waiting ${waitMs}ms before retry...');
    await Future.delayed(Duration(milliseconds: waitMs));
    _reinitializeClient();
  }

  /// Get available streams for a YouTube video - OPTIMIZED
  /// Only returns MUXED streams (video+audio combined) and audio-only
  /// Retrieves both standard (720p) and High-Res (1080p+) streams
  /// High-res DASH streams are marked to use the backend server
  Future<List<DetectedMedia>> getAvailableStreams(String url, {bool useBackendForDash = true}) async {
    final List<DetectedMedia> mediaList = [];

    try {
      final videoId = extractVideoId(url);
      if (videoId == null) return mediaList;

      _reinitializeClient();

      final video = await _executeWithRetry(() => yt.videos.get(videoId));
      final manifest = await _executeWithRetry(() => yt.videos.streamsClient.getManifest(videoId));
      final thumbnails = video.thumbnails.highResUrl;

      // 1. BEST AUDIO
      final bestAudio = manifest.audioOnly.withHighestBitrate();

      // 2. ROBUST VIDEO SELECTION (Fix for hanging 1080p)
      final dashByResolution = <String, VideoOnlyStreamInfo>{};

      // Sort streams to process the "safest" ones last (so they overwrite the risky ones)
      // Preference order: AV1 (risky) -> VP9 (okay) -> AVC/H.264 (Safe/Gold Standard)
      final sortedVideos = manifest.videoOnly.toList()
        ..sort((a, b) {
          int scoreA = _getCodecScore(a);
          int scoreB = _getCodecScore(b);
          return scoreA.compareTo(scoreB); // Low score first, High score (Safe) last
        });

      for (final stream in sortedVideos) {
        final height = stream.videoResolution.height;
        if (height < 1080) continue;

        // This will naturally keep the highest scoring (Safest) stream for each resolution
        dashByResolution['${height}p'] = stream;
      }

      // Add High-Res DASH streams (marked for backend download)
      for (final res in dashByResolution.keys) {
        final stream = dashByResolution[res]!;

        // Log to debug what we picked (Expect itag 137 for 1080p)
        print('Selected $res stream: itag=${_extractItag(stream.url.toString())} container=${stream.container.name}');

        mediaList.add(DetectedMedia(
          url: url, // Original URL for backend
          title: video.title,
          type: MediaType.video,
          source: MediaSource.youtube,
          thumbnailUrl: thumbnails,
          fileSize: stream.size.totalBytes + bestAudio.size.totalBytes,
          quality: '$res (HD)',
          format: 'mp4',
          isDash: true,
          audioUrl: bestAudio.url.toString(),
          videoId: videoId,
          useBackend: useBackendForDash, // Use backend for high-res
          backendQuality: res, // e.g., "1080p"
        ));
      }

      // 3. STANDARD STREAMS (Muxed) - these work without backend
      for (final stream in manifest.muxed) {
        final height = stream.videoResolution.height;
        if (height < 360) continue;
        if (dashByResolution.containsKey('${height}p')) continue;

        mediaList.add(DetectedMedia(
          url: stream.url.toString(),
          title: video.title,
          type: MediaType.video,
          source: MediaSource.youtube,
          thumbnailUrl: thumbnails,
          fileSize: stream.size.totalBytes,
          quality: '$height', // Simple quality label
          format: 'mp4',
          isDash: false,
          videoId: videoId,
          useBackend: false, // Muxed streams work fine directly
        ));
      }

      // 4. AUDIO ONLY
      mediaList.add(DetectedMedia(
        url: bestAudio.url.toString(),
        title: '${video.title} (Audio)',
        type: MediaType.audio,
        source: MediaSource.youtube,
        thumbnailUrl: thumbnails,
        fileSize: bestAudio.size.totalBytes,
        quality: 'Audio (${bestAudio.bitrate.kiloBitsPerSecond.toInt()}kbps)',
        format: 'm4a',
        isDash: false,
        videoId: videoId,
        useBackend: false,
      ));

      mediaList.sort((a, b) => (b.fileSize ?? 0).compareTo(a.fileSize ?? 0));

      return mediaList;
    } catch (e) {
      print('Error getting streams: $e');
      return mediaList;
    }
  }

  /// Helper to score codecs by stability
  /// 3 = AVC/H.264 (Gold Standard - Itag 137)
  /// 2 = VP9 (Standard WebM - Itag 248)
  /// 1 = AV1 (New/Risky - Itag 399)
  int _getCodecScore(VideoOnlyStreamInfo stream) {
    final codec = stream.videoCodec.toLowerCase();
    if (codec.startsWith('avc')) return 3; // Best for downloading
    if (codec.startsWith('vp9')) return 2;
    if (codec.startsWith('av01')) return 1; // Risky
    return 0;
  }
  /// Get the best quality muxed stream (video + audio)
  Future<DetectedMedia?> getBestMuxedStream(String url) async {
    try {
      final videoId = extractVideoId(url);
      if (videoId == null) return null;

      final video = await _executeWithRetry(() => yt.videos.get(videoId));
      final manifest = await _executeWithRetry(() => yt.videos.streamsClient.getManifest(videoId));

      final muxedStreams = manifest.muxed.toList()
        ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));

      if (muxedStreams.isEmpty) return null;

      final best = muxedStreams.first;
      return DetectedMedia(
        url: best.url.toString(),
        title: video.title,
        type: MediaType.video,
        source: MediaSource.youtube,
        thumbnailUrl: video.thumbnails.highResUrl,
        fileSize: best.size.totalBytes,
        quality: '${best.videoResolution}',
        format: best.container.name,
      );
    } catch (e) {
      print('Error getting best muxed stream: $e');
      return null;
    }
  }

  /// Get the best quality DASH streams (video + separate audio)
  Future<DetectedMedia?> getBestDashStream(String url) async {
    try {
      final videoId = extractVideoId(url);
      if (videoId == null) return null;

      final video = await _executeWithRetry(() => yt.videos.get(videoId));
      final manifest = await _executeWithRetry(() => yt.videos.streamsClient.getManifest(videoId));

      final videoStreams = manifest.videoOnly.toList()
        ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));

      final audioStreams = manifest.audioOnly.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (videoStreams.isEmpty || audioStreams.isEmpty) return null;

      final bestVideo = videoStreams.first;
      final bestAudio = audioStreams.first;

      return DetectedMedia(
        url: bestVideo.url.toString(),
        title: video.title,
        type: MediaType.video,
        source: MediaSource.youtube,
        thumbnailUrl: video.thumbnails.highResUrl,
        fileSize: bestVideo.size.totalBytes + bestAudio.size.totalBytes,
        quality: '${bestVideo.videoResolution} (DASH)',
        format: 'mp4',
        audioUrl: bestAudio.url.toString(),
        isDash: true,
      );
    } catch (e) {
      print('Error getting best DASH stream: $e');
      return null;
    }
  }

  // Rate limiting protection - track last manifest fetch time
  static DateTime? _lastManifestFetch;
  static const _minManifestInterval = Duration(seconds: 3);

  /// Download using youtube_explode streaming (most reliable method)
  Future<void> downloadStream({
    required String videoId,
    required String streamUrl,
    required String savePath,
    int? streamIndex,
    Function(double progress)? onProgress,
  }) async {
    print('Starting YouTube stream download for $videoId');
    
    // Rate limiting - wait between manifest fetches to avoid "VideoUnavailable" errors
    if (_lastManifestFetch != null) {
      final elapsed = DateTime.now().difference(_lastManifestFetch!);
      if (elapsed < _minManifestInterval) {
        final waitTime = _minManifestInterval - elapsed;
        print('Rate limiting: waiting ${waitTime.inMilliseconds}ms before fetching manifest...');
        await Future.delayed(waitTime);
      }
    }
    
    // Get fresh URL from youtube_explode
    _reinitializeClient();
    _lastManifestFetch = DateTime.now();
    
    final manifest = await yt.videos.streamsClient.getManifest(videoId)
        .timeout(const Duration(seconds: 30));
    
    final streamInfo = _findStreamByItag(manifest, streamUrl, streamIndex);
    final totalBytes = streamInfo.size.totalBytes;
    
    print('Got stream: ${streamInfo.runtimeType}, size: ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB');
    print('itag: ${_extractItag(streamInfo.url.toString())}');
    
    // Download using streaming
    final file = File(savePath);
    if (await file.exists()) {
      await file.delete();
    }
    
    final output = file.openWrite();
    final stream = yt.videos.streamsClient.get(streamInfo);
    
    int downloadedBytes = 0;
    int chunkCount = 0;
    int lastLoggedPercent = -1;
    
    try {
      await for (final chunk in stream.timeout(
        const Duration(seconds: 60),
        onTimeout: (sink) {
          print('WARNING: Stream timeout after 60s');
          sink.close();
        },
      )) {
        output.add(chunk);
        downloadedBytes += chunk.length;
        chunkCount++;
        
        if (chunkCount <= 5 || chunkCount % 100 == 0) {
          print('Chunk $chunkCount: ${chunk.length} bytes');
        }
        
        final progress = downloadedBytes / totalBytes;
        onProgress?.call(progress.clamp(0.0, 1.0));
        
        final percent = (progress * 100).toInt();
        if (percent ~/ 10 > lastLoggedPercent ~/ 10) {
          lastLoggedPercent = percent;
          print('Progress: $percent%');
        }
      }
      
      await output.flush();
      await output.close();
      
      print('Downloaded $chunkCount chunks, ${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB');
      
    } catch (e) {
      await output.close();
      print('Stream error: $e');
      rethrow;
    }
  }
  
  /// Find stream by itag or fallback
  StreamInfo _findStreamByItag(StreamManifest manifest, String streamUrl, int? streamIndex) {
    final allStreams = [...manifest.muxed, ...manifest.videoOnly, ...manifest.audioOnly];
    
    // Try match by itag (most reliable)
    final targetItag = _extractItag(streamUrl);
    if (targetItag != null) {
      for (final s in allStreams) {
        if (_extractItag(s.url.toString()) == targetItag) {
          return s;
        }
      }
    }
    
    // Fallback to index
    if (streamIndex != null && streamIndex < allStreams.length) {
      return allStreams[streamIndex];
    }
    
    // Fallback to best muxed
    if (manifest.muxed.isNotEmpty) {
      return (manifest.muxed.toList()..sort((a, b) => b.bitrate.compareTo(a.bitrate))).first;
    }
    
    return allStreams.first;
  }

  /// Check if a URL corresponds to a stream (by comparing itag or other params)
  bool _urlsMatchStream(String url, StreamInfo stream) {
    // Extract itag from both URLs for comparison
    final urlItag = _extractItag(url);
    final streamItag = _extractItag(stream.url.toString());
    
    if (urlItag != null && streamItag != null) {
      return urlItag == streamItag;
    }
    
    // Fallback: direct URL comparison (less reliable due to expiring tokens)
    return url == stream.url.toString();
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

  /// Download stream by video ID and quality preference
  Future<void> downloadByVideoId(
    String videoId,
    String savePath, {
    bool audioOnly = false,
    bool highestQuality = true,
    Function(double progress)? onProgress,
  }) async {
    try {
      final manifest = await _executeWithRetry(() => yt.videos.streamsClient.getManifest(videoId));
      
      StreamInfo streamInfo;
      
      if (audioOnly) {
        final audioStreams = manifest.audioOnly.toList()
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
        if (audioStreams.isEmpty) throw Exception('No audio streams available');
        streamInfo = highestQuality ? audioStreams.first : audioStreams.last;
      } else {
        // Prefer muxed streams (video+audio together)
        final muxedStreams = manifest.muxed.toList()
          ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
        if (muxedStreams.isEmpty) throw Exception('No muxed streams available');
        streamInfo = highestQuality ? muxedStreams.first : muxedStreams.last;
      }

      final stream = yt.videos.streamsClient.get(streamInfo);
      final file = File(savePath);
      final fileStream = file.openWrite();
      
      final totalBytes = streamInfo.size.totalBytes;
      var receivedBytes = 0;
      
      await for (final chunk in stream) {
        fileStream.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(receivedBytes / totalBytes);
        }
      }
      
      await fileStream.close();
    } catch (e) {
      print('Error downloading by video ID: $e');
      rethrow;
    }
  }

  /// Clean up resources
  void dispose() {
    _yt?.close();
  }

  /// Get video title by ID (for logging)
  Future<String> _getVideoTitle(String videoId) async {
    try {
      final video = await yt.videos.get(videoId);
      return video.title;
    } catch (_) {
      return videoId;
    }
  }

  /// Clear all caches
  void clearCache() {
    _manifestCache.clear();
    _videoCache.clear();
  }
}

/// Helper class for caching data with expiration
class _CachedData<T> {
  final T data;
  final DateTime cachedAt;
  
  _CachedData(this.data) : cachedAt = DateTime.now();
  
  bool get isExpired => DateTime.now().difference(cachedAt) > YouTubeService._cacheDuration;
}