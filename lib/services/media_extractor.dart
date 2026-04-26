import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

abstract class MediaExtractor {
  Future<String?> extractDirectMediaUrl(String sourceUrl);
}

class YouTubeExtractor implements MediaExtractor {
  YouTubeExtractor({YoutubeExplode? client})
    : _client = client ?? YoutubeExplode();

  final YoutubeExplode _client;

  static const Duration _manifestTimeout = Duration(seconds: 25);

  @override
  Future<String?> extractDirectMediaUrl(String sourceUrl) async {
    try {
      final videoId = VideoId.parseVideoId(sourceUrl);
      if (videoId == null) {
        debugPrint(
          'YouTubeExtractor rejected URL without video id: $sourceUrl',
        );
        return null;
      }

      final manifest = await _client.videos.streamsClient
          .getManifest(videoId)
          .timeout(_manifestTimeout);

      final muxedStreams = manifest.muxed.toList()
        ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
        );
      if (muxedStreams.isNotEmpty) {
        return muxedStreams.first.url.toString();
      }

      final videoOnlyStreams = manifest.videoOnly.toList()
        ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
        );
      if (videoOnlyStreams.isNotEmpty) {
        debugPrint(
          'YouTubeExtractor fallback: returning highest bitrate video-only stream.',
        );
        return videoOnlyStreams.first.url.toString();
      }

      final audioOnlyStreams = manifest.audioOnly.toList()
        ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
        );
      if (audioOnlyStreams.isNotEmpty) {
        debugPrint(
          'YouTubeExtractor fallback: returning highest bitrate audio-only stream.',
        );
        return audioOnlyStreams.first.url.toString();
      }

      debugPrint('YouTubeExtractor found no streams for: $sourceUrl');
      return null;
    } on TimeoutException catch (error, stackTrace) {
      debugPrint('YouTubeExtractor timeout: $error');
      debugPrint('$stackTrace');
      return null;
    } catch (error, stackTrace) {
      debugPrint('YouTubeExtractor failed: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  void dispose() {
    _client.close();
  }
}

class SocialMediaExtractor implements MediaExtractor {
  SocialMediaExtractor({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              sendTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              validateStatus: (status) => status != null && status < 600,
            ),
          );

  static const String _cobaltApiEndpoint = 'https://api.cobalt.tools/api/json';
  static const Duration _apiTimeout = Duration(seconds: 20);
  static const int _maxRetries = 3;
  static const Duration _baseRetryDelay = Duration(milliseconds: 500);

  final Dio _dio;

  @override
  Future<String?> extractDirectMediaUrl(String sourceUrl) async {
    // Try Cobalt API with retry
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      final result = await _tryExtractViaCobalt(sourceUrl);

      if (result != null) return result;

      // Check if we should retry (don't retry on rate limit or final attempt)
      if (attempt < _maxRetries - 1 && !_lastWasRateLimited) {
        final delay = _baseRetryDelay * (attempt + 1);
        debugPrint(
          'SocialMediaExtractor: Cobalt attempt ${attempt + 1} failed, '
          'retrying in ${delay.inMilliseconds}ms...',
        );
        await Future<void>.delayed(delay);
      } else {
        break;
      }
    }

    // Fallback: Try direct page scraping for OG/Twitter meta tags
    debugPrint('SocialMediaExtractor: Falling back to OG meta tag scraping');
    final ogResult = await _tryExtractViaOgMetaTags(sourceUrl);
    if (ogResult != null) return ogResult;

    debugPrint('SocialMediaExtractor: All extraction methods exhausted for $sourceUrl');
    return null;
  }

  bool _lastWasRateLimited = false;

  Future<String?> _tryExtractViaCobalt(String sourceUrl) async {
    _lastWasRateLimited = false;
    try {
      final response = await _dio
          .post<Map<String, dynamic>>(
            _cobaltApiEndpoint,
            data: <String, dynamic>{'url': sourceUrl},
            options: Options(
              headers: const <String, String>{
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              responseType: ResponseType.json,
            ),
          )
          .timeout(_apiTimeout);

      final statusCode = response.statusCode ?? 0;
      if (statusCode == 429) {
        debugPrint('SocialMediaExtractor rate limited by Cobalt API.');
        _lastWasRateLimited = true;
        return null;
      }

      if (statusCode < 200 || statusCode >= 300) {
        debugPrint(
          'SocialMediaExtractor unexpected Cobalt status: $statusCode',
        );
        return null;
      }

      final payload = response.data;
      if (payload == null) {
        debugPrint('SocialMediaExtractor received empty Cobalt response.');
        return null;
      }

      final cobaltStatus = payload['status'];
      if (cobaltStatus is String && cobaltStatus.toLowerCase() == 'error') {
        final message = payload['text'] ?? payload['error'] ?? 'Unknown error';
        debugPrint('SocialMediaExtractor Cobalt error: $message');
        return null;
      }

      final extractedUrl = _extractBestUrl(payload, sourceUrl);
      if (extractedUrl == null || !_isHttpUrl(extractedUrl)) {
        debugPrint('SocialMediaExtractor could not find a direct media URL.');
        return null;
      }

      return extractedUrl;
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 429) {
        debugPrint('SocialMediaExtractor rate limited by Cobalt API.');
        _lastWasRateLimited = true;
        return null;
      }

      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        debugPrint('SocialMediaExtractor timeout: ${error.message}');
        return null;
      }

      debugPrint('SocialMediaExtractor network failure: $error');
      return null;
    } on TimeoutException catch (error) {
      debugPrint('SocialMediaExtractor timeout: $error');
      return null;
    } catch (error) {
      debugPrint('SocialMediaExtractor failed: $error');
      return null;
    }
  }

  /// Fallback extraction via OG/Twitter meta tags from the page HTML.
  Future<String?> _tryExtractViaOgMetaTags(String sourceUrl) async {
    try {
      final response = await _dio.get<String>(
        sourceUrl,
        options: Options(
          headers: const <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml',
          },
          responseType: ResponseType.plain,
        ),
      ).timeout(const Duration(seconds: 10));

      final html = response.data;
      if (html == null || html.isEmpty) return null;

      // Extract media URLs from OG and Twitter meta tags
      final metaPatterns = [
        RegExp(r'<meta[^>]+property="og:video(?::url|:secure_url)?"[^>]+content="([^"]+)"', caseSensitive: false),
        RegExp(r'<meta[^>]+content="([^"]+)"[^>]+property="og:video(?::url|:secure_url)?"', caseSensitive: false),
        RegExp(r'<meta[^>]+name="twitter:player:stream"[^>]+content="([^"]+)"', caseSensitive: false),
        RegExp(r'<meta[^>]+content="([^"]+)"[^>]+name="twitter:player:stream"', caseSensitive: false),
      ];

      for (final pattern in metaPatterns) {
        for (final match in pattern.allMatches(html)) {
          final url = match.group(1)?.trim();
          if (url != null && _isHttpUrl(url) && _looksLikeDirectMediaUrl(url)) {
            debugPrint('SocialMediaExtractor: Found media URL via OG meta: $url');
            return url;
          }
        }
      }

      // Also try to find direct video URLs in JSON-LD structured data
      final jsonLdPattern = RegExp(
        r'"contentUrl"\s*:\s*"(https?://[^"]+)"',
        caseSensitive: false,
      );
      for (final match in jsonLdPattern.allMatches(html)) {
        final url = match.group(1)?.trim();
        if (url != null && _isHttpUrl(url)) {
          debugPrint('SocialMediaExtractor: Found media URL via JSON-LD: $url');
          return url;
        }
      }

      return null;
    } catch (e) {
      debugPrint('SocialMediaExtractor OG fallback failed: $e');
      return null;
    }
  }

  void dispose() {
    _dio.close(force: false);
  }

  String? _extractBestUrl(Map<String, dynamic> payload, String sourceUrl) {
    final discoveredUrls = <String>[];
    final pending = <dynamic>[payload];

    while (pending.isNotEmpty) {
      final current = pending.removeLast();

      if (current is Map) {
        final map = current.cast<dynamic, dynamic>();
        final urlValue = map['url'];
        if (urlValue is String && urlValue.trim().isNotEmpty) {
          discoveredUrls.add(urlValue.trim());
        }

        for (final value in map.values) {
          if (value is Map || value is List) {
            pending.add(value);
          }
        }
      } else if (current is List) {
        pending.addAll(current);
      }
    }

    if (discoveredUrls.isEmpty) {
      return null;
    }

    for (final candidate in discoveredUrls) {
      if (!_isHttpUrl(candidate)) {
        continue;
      }

      if (_looksLikeDirectMediaUrl(candidate)) {
        return candidate;
      }
    }

    for (final candidate in discoveredUrls) {
      if (!_isHttpUrl(candidate)) {
        continue;
      }

      if (candidate != sourceUrl) {
        return candidate;
      }
    }

    return discoveredUrls.firstWhere(_isHttpUrl, orElse: () => sourceUrl);
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  bool _looksLikeDirectMediaUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return false;
    }

    final path = uri.path.toLowerCase();
    const mediaExtensions = <String>{
      '.mp4',
      '.m4a',
      '.webm',
      '.mp3',
      '.mov',
      '.mkv',
      '.m3u8',
      '.aac',
      '.ogg',
      '.wav',
    };

    for (final extension in mediaExtensions) {
      if (path.endsWith(extension)) {
        return true;
      }
    }

    final host = uri.host.toLowerCase();
    return host.contains('cdn') ||
        host.contains('googlevideo.com') ||
        host.contains('fbcdn.net') ||
        host.contains('fbsbx.com') ||
        host.contains('cdninstagram.com') ||
        host.contains('tiktokcdn') ||
        host.contains('twimg.com') ||
        host.contains('video.twimg.com') ||
        host.contains('pbs.twimg.com') ||
        host.contains('akamaized.net') ||
        host.contains('cloudfront.net');
  }
}
