import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/detected_media.dart';

/// A service to extract media from platforms unsupported by NewPipe (e.g., TikTok, Instagram).
/// This provides a skeleton for a headless InAppWebView to navigate to a URL and intercept
/// network traffic looking for .mp4 or .m3u8 CDN links dynamically.
class WebViewExtractorService {
  HeadlessInAppWebView? _headlessWebView;

  /// Extract media from a generic URL using a hidden browser
  Future<List<DetectedMedia>> extractMedia(String url) async {
    final completer = Completer<List<DetectedMedia>>();
    final List<DetectedMedia> mediaList = [];

    _headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: 'Mozilla/5.0 (Linux; Android 10) Mobile Safari/537.36',
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      onLoadStop: (controller, url) async {
        // Wait for dynamic content
        await Future.delayed(const Duration(seconds: 3));

        final title = await controller.getTitle() ?? 'Extracted Video';

        if (mediaList.isNotEmpty) {
          if (!completer.isCompleted) completer.complete(mediaList);
        } else {
          // JS Fallback for <video> tags
          try {
            final result = await controller.evaluateJavascript(
              source: """
              (function() {
                var videos = document.getElementsByTagName('video');
                var urls = [];
                for(var i=0; i<videos.length; i++) {
                  if(videos[i].src) urls.push(videos[i].src);
                  else {
                    var sources = videos[i].getElementsByTagName('source');
                    if(sources.length > 0 && sources[0].src) urls.push(sources[0].src);
                  }
                }
                return urls;
              })();
            """,
            );

            if (result != null && result is List && result.isNotEmpty) {
              for (var src in result) {
                mediaList.add(
                  DetectedMedia(
                    url: src.toString(),
                    title: title,
                    type: MediaType.video,
                    source: MediaSource.generic,
                    format: 'mp4',
                    quality: 'Default',
                  ),
                );
              }
            }
          } catch (e) {
            debugPrint('JS extraction failed: $e');
          }

          if (!completer.isCompleted) completer.complete(mediaList);
        }
      },
      shouldInterceptRequest: (controller, request) async {
        final reqUrl = request.url.toString();
        // Intercept common video formats dynamically
        if (reqUrl.contains('.mp4') || reqUrl.contains('.m3u8')) {
          if (!mediaList.any((m) => m.url == reqUrl)) {
            mediaList.add(
              DetectedMedia(
                url: reqUrl,
                title: 'Intercepted Video',
                type: MediaType.video,
                source: MediaSource.generic,
                format: reqUrl.contains('.m3u8') ? 'm3u8' : 'mp4',
                quality: 'Stream',
              ),
            );
          }
        }
        return null; // Return null to let request proceed
      },
    );

    await _headlessWebView?.run();

    // Safety timeout
    Future.delayed(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.complete(mediaList);
        _headlessWebView?.dispose();
      }
    });

    final result = await completer.future;
    _headlessWebView?.dispose();
    return result;
  }
}
