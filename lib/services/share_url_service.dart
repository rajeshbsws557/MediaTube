class ShareUrlService {
  static final RegExp _httpUrlRegex = RegExp(r'https?://[^\s]+');
  static final RegExp _facebookDeepLinkRegex = RegExp(
    r'fb://fullscreen_video/(\d+)',
    caseSensitive: false,
  );

  /// Extract and normalize a shared value into a browser-loadable http(s) URL.
  static String? normalizeSharedUrl(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return null;

    final normalizedInput = _stripTrailingPunctuation(trimmed);

    final httpMatch = _httpUrlRegex.firstMatch(normalizedInput);
    if (httpMatch != null) {
      return _sanitizeHttpUrl(httpMatch.group(0)!);
    }

    if (normalizedInput.toLowerCase().startsWith('fb://')) {
      return _normalizeFacebookDeepLink(normalizedInput);
    }

    return null;
  }

  static bool isSupportedWebUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
  }

  static String _sanitizeHttpUrl(String url) {
    var cleaned = _stripTrailingPunctuation(url);

    // Common share params that often break extraction freshness.
    final uri = Uri.tryParse(cleaned);
    if (uri == null) return cleaned;

    if (uri.queryParameters.containsKey('si')) {
      final params = Map<String, String>.from(uri.queryParameters)
        ..remove('si');
      cleaned = uri.replace(queryParameters: params.isEmpty ? null : params).toString();
    }

    final normalizedFacebook = _normalizeFacebookWebUrl(cleaned);
    if (normalizedFacebook != null) {
      cleaned = normalizedFacebook;
    }

    return cleaned;
  }

  static String? _normalizeFacebookWebUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    final isFacebookHost = host.contains('facebook.com') || host.contains('fb.watch');
    if (!isFacebookHost) return null;

    final watchParam = uri.queryParameters['v'] ?? uri.queryParameters['video_id'];
    if (watchParam != null && watchParam.isNotEmpty) {
      return 'https://m.facebook.com/watch/?v=$watchParam';
    }

    final storyFbid = uri.queryParameters['story_fbid'];
    final idParam = uri.queryParameters['id'];
    if (storyFbid != null && storyFbid.isNotEmpty && idParam != null && idParam.isNotEmpty) {
      return 'https://m.facebook.com/$idParam/videos/$storyFbid/';
    }

    if (host.contains('fb.watch')) {
      // Keep short links on mobile web host to improve in-app playback compatibility.
      return 'https://m.facebook.com${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    }

    if (host.startsWith('www.facebook.com') || host.startsWith('facebook.com')) {
      return 'https://m.facebook.com${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    }

    return null;
  }

  static String? _normalizeFacebookDeepLink(String deepLink) {
    final match = _facebookDeepLinkRegex.firstMatch(deepLink);
    if (match != null) {
      final videoId = match.group(1)!;
      return 'https://www.facebook.com/watch/?v=$videoId';
    }

    final uri = Uri.tryParse(deepLink);
    if (uri != null) {
      final fromQuery = uri.queryParameters['video_id'] ??
          uri.queryParameters['v'] ??
          uri.queryParameters['story_fbid'];
      if (fromQuery != null && fromQuery.isNotEmpty) {
        return 'https://www.facebook.com/watch/?v=$fromQuery';
      }
    }

    return null;
  }

  static String _stripTrailingPunctuation(String value) {
    return value.replaceAll(RegExp(r'[.,!?;:]+$'), '');
  }
}