import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/detected_media.dart';
import 'media_sniffer_service.dart';

/// A service to extract media from platforms unsupported by NewPipe (e.g., TikTok, Instagram).
/// This provides a skeleton for a headless InAppWebView to navigate to a URL and intercept
/// network traffic looking for .mp4 or .m3u8 CDN links dynamically.
class WebViewExtractorService {
  final MediaSnifferService _sniffer = MediaSnifferService();
  final Map<String, _CachedExtractionResult> _cache =
      <String, _CachedExtractionResult>{};
  final Map<String, Future<List<DetectedMedia>>> _inFlight =
      <String, Future<List<DetectedMedia>>>{};

  static const Duration _overallTimeout = Duration(seconds: 8);
  static const Duration _cacheTtl = Duration(minutes: 3);
  static const List<Duration> _domScanDelays = [
    Duration(milliseconds: 120),
    Duration(milliseconds: 220),
    Duration(milliseconds: 350),
    Duration(milliseconds: 560),
  ];

  void _addMediaIfNew(List<DetectedMedia> mediaList, DetectedMedia media) {
    final exists = mediaList.any((m) => m.url == media.url);
    if (!exists) {
      mediaList.add(media);
    }
  }

  Future<void> _scanDomForMedia(
    InAppWebViewController controller,
    List<DetectedMedia> mediaList,
    String title,
  ) async {
    final result = await controller.evaluateJavascript(
      source: """
        (function() {
          function toAbsolute(value) {
            if (!value) return null;
            try {
              return new URL(value, window.location.href).toString();
            } catch (e) {
              return value;
            }
          }

          var videos = document.querySelectorAll('video, source');
          var metas = document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="twitter:player:stream"]');
          var urls = [];
          for(var i=0; i<videos.length; i++) {
            if(videos[i].src) urls.push(toAbsolute(videos[i].src));
          }

          for (var m=0; m<metas.length; m++) {
            var metaUrl = metas[m].getAttribute('content');
            if (metaUrl) urls.push(toAbsolute(metaUrl));
          }

          var anchors = document.querySelectorAll('a[href*=".mp4"], a[href*=".m3u8"], a[href*="video"]');
          for (var a=0; a<anchors.length; a++) {
            var href = anchors[a].getAttribute('href');
            if (href) urls.push(toAbsolute(href));
          }

          return Array.from(new Set(urls.filter(Boolean)));
        })();
      """,
    );

    if (result != null && result is List && result.isNotEmpty) {
      for (var src in result) {
        final detected = _sniffer.detectMedia(
          src.toString(),
          pageTitle: title,
        );
        if (detected != null) {
          _addMediaIfNew(mediaList, detected);
        }
      }
    }
  }

  String _normalizeKey(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return rawUrl;
    }
    return uri.replace(fragment: null).toString();
  }

  List<DetectedMedia>? _getCached(String key) {
    final cached = _cache[key];
    if (cached == null) {
      return null;
    }

    if (DateTime.now().difference(cached.timestamp) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }

    return List<DetectedMedia>.from(cached.media);
  }

  /// Extract media from a generic URL using a hidden browser
  Future<List<DetectedMedia>> extractMedia(String url) async {
    final key = _normalizeKey(url);

    final cached = _getCached(key);
    if (cached != null) {
      return cached;
    }

    final existingInFlight = _inFlight[key];
    if (existingInFlight != null) {
      return existingInFlight;
    }

    final extractionFuture = _extractMediaInternal(url, cacheKey: key);
    _inFlight[key] = extractionFuture;

    try {
      return await extractionFuture;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<List<DetectedMedia>> _extractMediaInternal(
    String url, {
    required String cacheKey,
  }) async {
    final completer = Completer<List<DetectedMedia>>();
    final List<DetectedMedia> mediaList = [];
    final startedAt = DateTime.now();
    HeadlessInAppWebView? headlessWebView;

    void completeExtraction({bool force = false}) {
      if (completer.isCompleted) return;
      if (!force && mediaList.isEmpty) return;
      final output = List<DetectedMedia>.from(mediaList);
      _cache[cacheKey] = _CachedExtractionResult(
        media: output,
        timestamp: DateTime.now(),
      );
      completer.complete(output);
    }

    void maybeCompleteEarly() {
      final elapsed = DateTime.now().difference(startedAt);
      if (mediaList.length >= 2) {
        completeExtraction();
        return;
      }
      if (mediaList.isNotEmpty && elapsed >= const Duration(milliseconds: 1200)) {
        completeExtraction();
      }
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: 'Mozilla/5.0 (Linux; Android 10) Mobile Safari/537.36',
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      onLoadStop: (controller, url) async {
        final title = await controller.getTitle() ?? 'Extracted Video';

        try {
          for (final delay in _domScanDelays) {
            if (completer.isCompleted) break;
            await Future.delayed(delay);
            await _scanDomForMedia(controller, mediaList, title);
            maybeCompleteEarly();
          }
        } catch (e) {
          debugPrint('JS extraction failed: $e');
        } finally {
          completeExtraction(force: true);
        }
      },
      shouldInterceptRequest: (controller, request) async {
        final reqUrl = request.url.toString();
        final detected = _sniffer.detectMedia(
          reqUrl,
          pageTitle: 'Intercepted Video',
        );
        if (detected != null) {
          _addMediaIfNew(mediaList, detected);
          maybeCompleteEarly();
        }
        return null; // Return null to let request proceed
      },
    );

    try {
      await headlessWebView.run();
    } catch (e) {
      debugPrint('Headless extractor run failed: $e');
      completeExtraction(force: true);
    }

    // Safety timeout
    final timeoutTimer = Timer(_overallTimeout, () {
      completeExtraction(force: true);
    });

    final result = await completer.future;
    timeoutTimer.cancel();
    headlessWebView.dispose();
    return result;
  }
}

class _CachedExtractionResult {
  final List<DetectedMedia> media;
  final DateTime timestamp;

  const _CachedExtractionResult({
    required this.media,
    required this.timestamp,
  });
}
