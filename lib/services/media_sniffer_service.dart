import '../models/detected_media.dart';

/// Service to detect media URLs from network traffic
class MediaSnifferService {
  // Media file extensions to detect
  static const List<String> _videoExtensions = ['.mp4', '.webm', '.mkv', '.avi', '.mov', '.flv'];
  static const List<String> _audioExtensions = ['.mp3', '.aac', '.m4a', '.wav', '.flac', '.ogg'];
  static const List<String> _streamExtensions = ['.m3u8', '.mpd'];

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
  DetectedMedia? detectMedia(String url, {String? pageTitle}) {
    final lowerUrl = url.toLowerCase();

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
          format: ext.replaceFirst('.', ''),
        );
      }
    }

    // Check for content-type hints in URL
    if (lowerUrl.contains('video') && 
        (lowerUrl.contains('mp4') || lowerUrl.contains('download'))) {
      return DetectedMedia(
        url: url,
        title: pageTitle ?? 'Video',
        type: MediaType.video,
      );
    }

    return null;
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
}
