import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../utils/url_input_sanitizer.dart';
import 'share_url_service.dart';

class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  static final RegExp _httpUrlRegex = RegExp(
    r'https?://[^\s<>"\]\)]+',
    caseSensitive: false,
  );

  final StreamController<String> _sharedUrlController =
      StreamController<String>.broadcast();

  StreamSubscription<List<SharedMediaFile>>? _runtimeIntentSubscription;
  bool _isInitialized = false;

  Stream<String> get sharedUrlStream => _sharedUrlController.stream;

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    _isInitialized = true;

    _runtimeIntentSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          _processSharedItems,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('ShareIntentService stream error: $error');
            debugPrint('$stackTrace');
          },
        );

    try {
      final initialItems = await ReceiveSharingIntent.instance
          .getInitialMedia();
      _processSharedItems(initialItems);
      await ReceiveSharingIntent.instance.reset();
    } catch (error, stackTrace) {
      debugPrint('ShareIntentService initial intent error: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> dispose() async {
    await _runtimeIntentSubscription?.cancel();
    _runtimeIntentSubscription = null;
    _isInitialized = false;
  }

  void _processSharedItems(List<SharedMediaFile> sharedItems) {
    if (sharedItems.isEmpty) {
      return;
    }

    for (final item in sharedItems) {
      final candidates = <String>[
        item.path,
        if ((item.message ?? '').trim().isNotEmpty) item.message!.trim(),
      ];

      for (final candidate in candidates) {
        final extractedUrl = extractFirstUrl(candidate);
        if (extractedUrl != null) {
          _sharedUrlController.add(extractedUrl);
          return;
        }

        final normalized = ShareUrlService.normalizeSharedUrl(candidate);
        if (normalized != null &&
            UrlInputSanitizer.isHttpOrHttpsUrl(normalized)) {
          _sharedUrlController.add(normalized);
          return;
        }
      }
    }
  }

  String? extractFirstUrl(String sharedContent) {
    var trimmed = sharedContent.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    try {
      final decoded = Uri.decodeFull(trimmed);
      if (decoded.trim().isNotEmpty) {
        trimmed = decoded.trim();
      }
    } catch (_) {}

    final match = _httpUrlRegex.firstMatch(trimmed);
    if (match == null) {
      final normalizedWhole = UrlInputSanitizer.sanitizeToNavigableUrl(trimmed);
      if (normalizedWhole != null &&
          UrlInputSanitizer.isHttpOrHttpsUrl(normalizedWhole)) {
        return normalizedWhole;
      }

      return null;
    }

    final rawUrl = _stripTrailingPunctuation(match.group(0)!);
    final sanitizedUrl = UrlInputSanitizer.sanitizeToNavigableUrl(rawUrl);

    if (sanitizedUrl == null ||
        !UrlInputSanitizer.isHttpOrHttpsUrl(sanitizedUrl)) {
      return null;
    }

    return sanitizedUrl;
  }

  String _stripTrailingPunctuation(String value) {
    return value.replaceAll(RegExp(r'[.,!?;:]+$'), '');
  }
}
