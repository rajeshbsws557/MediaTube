import '../models/detected_media.dart';

/// Service to detect media URLs from network traffic
class MediaSnifferService {
  // Media file extensions to detect
  static const List<String> _videoExtensions = ['.mp4', '.webm', '.mkv', '.avi', '.mov', '.flv'];
  static const List<String> _audioExtensions = ['.mp3', '.aac', '.m4a', '.wav', '.flac', '.ogg'];
  static const List<String> _streamExtensions = ['.m3u8', '.mpd'];

  static const List<String> _videoMimeHints = [
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'application/x-mpegurl',
    'application/vnd.apple.mpegurl',
    'application/dash+xml',
  ];

  static const List<String> _knownVideoCdnHosts = [
    'cdninstagram.com',
    'fbcdn.net',
    'fbsbx.com',
    'akamaihd.net',
    'video.fbcdn.net',
    'video.xx.fbcdn.net',
    'scontent.cdninstagram.com',
    'cdn.tiktokcdn.com',
    'v16-webapp.tiktok.com',
    'muscdn.com',
    'tiktokcdn-us.com',
    'twimg.com',
    'video.twimg.com',
    'pbs.twimg.com',
  ];

  // URL patterns to ignore (ads, tracking, etc.)
  static const List<String> _ignorePatterns = [
    'googlevideo.com/videoplayback', // YouTube's own player
    'googleads',
    'doubleclick',
    'analytics',
    'tracking',
    'pixel',
    'beacon',
    '.gif',
    '.png',
    '.jpg',
    '.jpeg',
    '.ico',
    '.svg',
    '.css',
    '.js',
    'fonts.googleapis',
  ];

  /// Check if URL contains a detectable media file
  DetectedMedia? detectMedia(
    String url, {
    String? pageTitle,
    String? contentType,
  }) {
    final lowerUrl = url.toLowerCase();

    if (lowerUrl.startsWith('blob:') ||
        lowerUrl.startsWith('data:') ||
        lowerUrl.startsWith('about:')) {
      return null;
    }

    // Skip ignored patterns
    for (final pattern in _ignorePatterns) {
      if (lowerUrl.contains(pattern)) {
        return null;
      }
    }

    // Check for video files
    for (final ext in _videoExtensions) {
      if (_hasExtension(lowerUrl, ext)) {
        return DetectedMedia(
          url: url,
          title: pageTitle ?? _extractFileName(url) ?? 'Video',
          type: MediaType.video,
          fileSize: _extractFileSizeHint(url),
          format: ext.replaceFirst('.', ''),
        );
      }
    }

    // Check for audio files
    for (final ext in _audioExtensions) {
      if (_hasExtension(lowerUrl, ext)) {
        return DetectedMedia(
          url: url,
          title: pageTitle ?? _extractFileName(url) ?? 'Audio',
          type: MediaType.audio,
          fileSize: _extractFileSizeHint(url),
          format: ext.replaceFirst('.', ''),
        );
      }
    }

    // Check for stream files (HLS, DASH)
    for (final ext in _streamExtensions) {
      if (_hasExtension(lowerUrl, ext)) {
        return DetectedMedia(
          url: url,
          title: pageTitle ?? 'Live Stream',
          type: MediaType.stream,
          fileSize: _extractFileSizeHint(url),
          format: ext.replaceFirst('.', ''),
        );
      }
    }

    if (contentType != null) {
      final lowerType = contentType.toLowerCase();
      if (_videoMimeHints.any((hint) => lowerType.contains(hint))) {
        final streamLike =
            lowerType.contains('mpegurl') || lowerType.contains('dash+xml');
        return DetectedMedia(
          url: url,
          title: pageTitle ?? (streamLike ? 'Live Stream' : 'Video'),
          type: streamLike ? MediaType.stream : MediaType.video,
          fileSize: _extractFileSizeHint(url),
          format: streamLike ? 'm3u8' : _inferFormatFromUrl(lowerUrl),
        );
      }
    }

    if (_looksLikePlatformVideoUrl(lowerUrl)) {
      return DetectedMedia(
        url: url,
        title: pageTitle ?? 'Video',
        type: MediaType.video,
        fileSize: _extractFileSizeHint(url),
        format: _inferFormatFromUrl(lowerUrl),
      );
    }

    // Check for content-type hints in URL
    if (lowerUrl.contains('video') && 
        (lowerUrl.contains('mp4') || lowerUrl.contains('download'))) {
      return DetectedMedia(
        url: url,
        title: pageTitle ?? 'Video',
        type: MediaType.video,
        fileSize: _extractFileSizeHint(url),
      );
    }

    return null;
  }

  bool _looksLikePlatformVideoUrl(String lowerUrl) {
    final hasKnownHost = _knownVideoCdnHosts.any((h) => lowerUrl.contains(h));
    if (!hasKnownHost) return false;

    // Fast-path for major social CDNs that often omit clear file extensions.
    if (lowerUrl.contains('fbcdn.net') ||
        lowerUrl.contains('fbsbx.com') ||
        lowerUrl.contains('cdninstagram.com') ||
        lowerUrl.contains('video.twimg.com') ||
        lowerUrl.contains('tiktokcdn')) {
      final hasSocialVideoMarker =
          lowerUrl.contains('/v/t') ||
          lowerUrl.contains('/video') ||
          lowerUrl.contains('/hvideo') ||
          lowerUrl.contains('stp=') ||
          lowerUrl.contains('ccb=') ||
          lowerUrl.contains('oe=') ||
          lowerUrl.contains('oh=') ||
          lowerUrl.contains('mime=video') ||
          lowerUrl.contains('content_type=video') ||
          lowerUrl.contains('bytestart=') ||
          lowerUrl.contains('byteend=');
      if (hasSocialVideoMarker) return true;
    }

    return lowerUrl.contains('bytestart=') ||
        lowerUrl.contains('byteend=') ||
        lowerUrl.contains('mime=video') ||
        lowerUrl.contains('mime_type=video') ||
        lowerUrl.contains('content_type=video') ||
        lowerUrl.contains('oe=') ||
        lowerUrl.contains('oh=') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.contains('/play/') ||
        lowerUrl.contains('/reel/') ||
        lowerUrl.contains('/playlist/') ||
        lowerUrl.contains('videoplayback');
  }

  String _inferFormatFromUrl(String lowerUrl) {
    if (_hasExtension(lowerUrl, '.m3u8')) return 'm3u8';
    if (_hasExtension(lowerUrl, '.mpd')) return 'mpd';
    if (_hasExtension(lowerUrl, '.webm')) return 'webm';
    if (_hasExtension(lowerUrl, '.mov')) return 'mov';
    if (_hasExtension(lowerUrl, '.mp4')) return 'mp4';
    return 'mp4';
  }

  bool _hasExtension(String url, String ext) {
    // Check if URL ends with extension or has extension before query params
    if (url.endsWith(ext)) return true;
    if (url.contains('$ext?')) return true;
    if (url.contains('$ext&')) return true;
    return false;
  }

  String? _extractFileName(String url) {
    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;
      if (pathSegments.isNotEmpty) {
        final lastSegment = pathSegments.last;
        // Remove query parameters and return
        final fileName = lastSegment.split('?').first;
        if (fileName.isNotEmpty && fileName.contains('.')) {
          return Uri.decodeComponent(fileName);
        }
      }
    } catch (_) {}
    return null;
  }

  int? _extractFileSizeHint(String url) {
    try {
      final uri = Uri.parse(url);
      final qp = uri.queryParameters;

      int? parseIntParam(String key) {
        final v = qp[key];
        if (v == null || v.isEmpty) return null;
        return int.tryParse(v);
      }

      final explicitSize =
          parseIntParam('content_length') ??
          parseIntParam('clen') ??
          parseIntParam('filesize') ??
          parseIntParam('size');
      if (explicitSize != null && explicitSize > 0) return explicitSize;

      final start = parseIntParam('bytestart');
      final end = parseIntParam('byteend');
      if (start != null && end != null && end >= start) {
        final span = (end - start) + 1;
        if (span > 0) return span;
      }
    } catch (_) {}

    return null;
  }

  /// Check if URL is from YouTube
  bool isYouTubeUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('youtube.com') || 
           lowerUrl.contains('youtu.be') ||
           lowerUrl.contains('youtube-nocookie.com');
  }

  /// Check if URL is from Instagram
  bool isInstagramUrl(String url) {
    return url.toLowerCase().contains('instagram.com');
  }

  /// Check if URL is from TikTok
  bool isTikTokUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('tiktok.com') ||
        lowerUrl.contains('vm.tiktok.com') ||
        lowerUrl.contains('vt.tiktok.com');
  }

  /// Check if URL is from Twitter/X
  bool isTwitterUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('twitter.com') || lowerUrl.contains('x.com');
  }

  /// Check if URL is from Facebook
  bool isFacebookUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('facebook.com') || lowerUrl.contains('fb.watch');
  }

  /// Check if URL belongs to a major social platform with embedded video
  bool isSupportedSocialVideoUrl(String url) {
    return isFacebookUrl(url) ||
        isInstagramUrl(url) ||
        isTwitterUrl(url) ||
        isTikTokUrl(url);
  }
}
