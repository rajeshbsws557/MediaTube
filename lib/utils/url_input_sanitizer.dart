class UrlInputSanitizer {
  static final RegExp _invalidControlChars = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _ipv4Regex = RegExp(
    r'^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(:\d{1,5})?$',
  );
  static final RegExp _hostLikeRegex = RegExp(
    r'^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+(:\d{1,5})?$',
  );

  static String? sanitizeToNavigableUrl(String rawInput) {
    final input = _normalizeInput(rawInput);
    if (input.isEmpty) {
      return null;
    }

    if (!_hasHttpScheme(input)) {
      if (_looksLikeHost(input)) {
        return _normalizeHttpUri('https://$input');
      }
      return _searchUrl(input);
    }

    return _normalizeHttpUri(input);
  }

  static bool isHttpOrHttpsUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  static String _searchUrl(String query) {
    final sanitized = _normalizeInput(query);
    return 'https://duckduckgo.com/?q=${Uri.encodeComponent(sanitized)}';
  }

  static String _normalizeInput(String value) {
    return value.trim().replaceAll(_invalidControlChars, '');
  }

  static bool _hasHttpScheme(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static bool _looksLikeHost(String value) {
    final hostCandidate = value.split('/').first.trim();
    if (hostCandidate.isEmpty || hostCandidate.contains(' ')) {
      return false;
    }

    if (hostCandidate.toLowerCase() == 'localhost' ||
        hostCandidate.toLowerCase().startsWith('localhost:')) {
      return true;
    }

    if (_ipv4Regex.hasMatch(hostCandidate)) {
      return true;
    }

    return _hostLikeRegex.hasMatch(hostCandidate);
  }

  static String? _normalizeHttpUri(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return null;
    }

    return uri.toString();
  }
}