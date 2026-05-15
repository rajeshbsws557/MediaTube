class ShareUrlService {
  static final RegExp _httpUrlRegex = RegExp(r'https?://[^\s]+');
  static final RegExp _facebookDeepLinkRegex = RegExp(
    r'fb://fullscreen_video/(\d+)',
    caseSensitive: false,
  );
  static final Set<String> _trackingParams = {
    'si',
    's',
    'fbclid',
    'igshid',
    'ig_rid',
    'ig_mid',
    'mibextid',
    'ttclid',
    'feature',
    'refsrc',
    '_rdr',
    'source',
  };

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

    final unwrapped = _unwrapKnownRedirect(uri);
    if (unwrapped != null && unwrapped != cleaned) {
      return _sanitizeHttpUrl(unwrapped);
    }

    final sanitizedUri = _stripTrackingParams(uri);
    cleaned = sanitizedUri.toString();

    final normalizedFacebook = _normalizeFacebookWebUrl(cleaned);
    if (normalizedFacebook != null) {
      return normalizedFacebook;
    }

    final normalizedInstagram = _normalizeInstagramWebUrl(cleaned);
    if (normalizedInstagram != null) {
      return normalizedInstagram;
    }

    final normalizedTwitter = _normalizeTwitterWebUrl(cleaned);
    if (normalizedTwitter != null) {
      return normalizedTwitter;
    }

    final normalizedTikTok = _normalizeTikTokWebUrl(cleaned);
    if (normalizedTikTok != null) {
      return normalizedTikTok;
    }

    return cleaned;
  }

  static Uri _stripTrackingParams(Uri uri) {
    if (uri.queryParameters.isEmpty) {
      return uri;
    }

    final sanitized = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      final lower = key.toLowerCase();
      if (_trackingParams.contains(lower) || lower.startsWith('utm_')) {
        return;
      }
      sanitized[key] = value;
    });

    return uri.replace(
      queryParameters: sanitized.isEmpty ? null : sanitized,
      fragment: null,
    );
  }

  static String? _unwrapKnownRedirect(Uri uri) {
    final host = uri.host.toLowerCase();
    final qp = uri.queryParameters;

    if (host == 'l.facebook.com' ||
        host == 'lm.facebook.com' ||
        (host.endsWith('facebook.com') && uri.path.toLowerCase() == '/l.php')) {
      final target = qp['u'] ?? qp['url'] ?? qp['target'];
      if (target != null && target.isNotEmpty) {
        return Uri.decodeFull(target);
      }
    }

    if ((host.endsWith('instagram.com') || host == 'instagr.am') &&
        uri.path.toLowerCase() == '/linkshim/') {
      final target = qp['u'] ?? qp['url'];
      if (target != null && target.isNotEmpty) {
        return Uri.decodeFull(target);
      }
    }

    return null;
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

  static String? _normalizeInstagramWebUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (!host.contains('instagram.com') && host != 'instagr.am') {
      return null;
    }

    final path = uri.path;
    if (path.contains('/reel/') || path.contains('/p/') || path.contains('/tv/')) {
      final normalizedPath = path.endsWith('/') ? path : '$path/';
      return 'https://www.instagram.com$normalizedPath';
    }

    return 'https://www.instagram.com${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  }

  static String? _normalizeTwitterWebUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (!(host.contains('x.com') || host.contains('twitter.com'))) {
      return null;
    }

    final path = uri.path;
    final match = RegExp(r'^/([^/]+)/status/(\d+)').firstMatch(path);
    if (match != null) {
      return 'https://x.com/${match.group(1)}/status/${match.group(2)}';
    }

    final webStatus = RegExp(r'^/i/web/status/(\d+)').firstMatch(path);
    if (webStatus != null) {
      return 'https://x.com/i/status/${webStatus.group(1)}';
    }

    return 'https://x.com${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  }

  static String? _normalizeTikTokWebUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (!(host.contains('tiktok.com'))) {
      return null;
    }

    if (host == 'vm.tiktok.com' || host == 'vt.tiktok.com') {
      return uri.replace(fragment: null).toString();
    }

    return 'https://www.tiktok.com${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
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