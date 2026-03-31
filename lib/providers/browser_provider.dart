import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/models.dart';
import '../services/services.dart';

/// Provider for managing media detection and browser state
/// Optimized for instant stream loading with aggressive caching
class BrowserProvider extends ChangeNotifier {
  final MediaSnifferService _snifferService = MediaSnifferService();
  final YouTubeService _youtubeService = YouTubeService();
  final WebViewExtractorService _webviewExtractor = WebViewExtractorService();

  final List<BrowserTab> _tabs = [BrowserTab(url: 'https://youtube.com')];
  int _activeTabIndex = 0;

  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  // Detected media
  final List<DetectedMedia> _detectedMedia = [];
  bool _isYouTubePage = false;
  bool _isSocialVideoPage = false;
  bool _isFetchingYouTube = false;
  bool _isFetchingGeneric = false;
  String? _fetchError;

  // Track current YouTube video to detect navigation within YouTube
  String? _currentYouTubeVideoId;

  // Debounce timer for stream fetching
  Timer? _fetchDebounceTimer;
  Timer? _genericFetchDebounceTimer;

  // PERSISTENT cache - survives sheet open/close, holds multiple videos
  static final Map<String, List<DetectedMedia>> _streamCache = {};
  static const int _maxCacheSize = 50; // Increased cache for more videos
  static const int _maxDetectedMediaItems = 24;
  static const Set<String> _volatileSegmentParams = {
    'bytestart',
    'byteend',
    'range',
    'start',
    'end',
    'part',
    'chunk',
    'segment',
    'seq',
    'rn',
    'rbuf',
  };

  final Dio _metadataDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      followRedirects: true,
      maxRedirects: 5,
    ),
  );
  final Queue<String> _sizeProbeQueue = Queue<String>();
  final Set<String> _sizeProbeInFlight = <String>{};
  final Map<String, int> _resolvedSizeByUrl = <String, int>{};
  bool _sizeProbePumpRunning = false;

  final Map<String, int> _recentResourceHits = <String, int>{};
  int _resourceHitInsertions = 0;
  Timer? _resourceNotifyTimer;
  bool _resourceNotifyPending = false;
  static const int _resourceDedupWindowMs = 2500;
  static const int _maxRecentResourceEntries = 600;
  static const Duration _resourceNotifyInterval = Duration(milliseconds: 120);
  static const Set<String> _resourceDedupVolatileParams = {
    'bytestart',
    'byteend',
    'range',
    'start',
    'end',
    'part',
    'chunk',
    'segment',
    'seq',
    'rn',
    'rbuf',
    'oh',
    'oe',
    'ccb',
    'stp',
    '_nc_cat',
    '_nc_zt',
    '_nc_ht',
    '_nc_rid',
    '_nc_sid',
    'efg',
    'vs',
    'nc',
  };

  // Share Intent Support - queue to handle rapid successive shares
  final List<String> _pendingUrls = [];

  // Getters
  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  int get activeTabIndex => _activeTabIndex;
  BrowserTab get activeTab => _tabs[_activeTabIndex];

  String get currentUrl => _tabs[_activeTabIndex].url;
  String get pageTitle => _tabs[_activeTabIndex].title;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  List<DetectedMedia> get detectedMedia => List.unmodifiable(_detectedMedia);
  bool get hasDetectedMedia => _detectedMedia.isNotEmpty;
  bool get isYouTubePage => _isYouTubePage;
  bool get isSocialVideoPage => _isSocialVideoPage;
  bool get isFetchingYouTube => _isFetchingYouTube;
  bool get isFetchingGeneric => _isFetchingGeneric;
  bool get isFetchingMedia => _isFetchingYouTube || _isFetchingGeneric;
  bool get shouldObserveNetworkMedia =>
      _isSocialVideoPage || _isFetchingGeneric || _detectedMedia.isNotEmpty;
  String? get fetchError => _fetchError;
  bool get hasFetchError => _fetchError != null;

  /// Returns the next pending URL or null if the queue is empty.
  String? get pendingUrl => _pendingUrls.isNotEmpty ? _pendingUrls.first : null;

  void setPendingUrl(String url) {
    _pendingUrls.add(url);
    notifyListeners();
  }

  void consumePendingUrl() {
    if (_pendingUrls.isNotEmpty) {
      _pendingUrls.removeAt(0);
    }
    // Don't call notifyListeners here to avoid recursive listener loops.
    // The caller is responsible for proceeding after consuming.
  }

  void setLoading(bool loading) {
    if (_isLoading == loading) {
      return;
    }
    _isLoading = loading;
    notifyListeners();
  }

  void setCurrentUrl(String url) {
    if (url == _tabs[_activeTabIndex].url) return;

    _tabs[_activeTabIndex].url = url;

    // Check if this is a YouTube page
    final wasYouTube = _isYouTubePage;
    _isYouTubePage = _snifferService.isYouTubeUrl(url);
    _isSocialVideoPage = _snifferService.isSupportedSocialVideoUrl(url);

    // Extract YouTube video ID
    final newVideoId = _isYouTubePage
        ? _youtubeService.extractVideoId(url)
        : null;
    final videoChanged = newVideoId != _currentYouTubeVideoId;
    _currentYouTubeVideoId = newVideoId;

    // If we just navigated to YouTube or video changed
    if (_isYouTubePage && (!wasYouTube || videoChanged)) {
      _detectedMedia.clear();
      _fetchError = null;

      // INSTANT loading from cache - no fetch needed!
      if (newVideoId != null && _streamCache.containsKey(newVideoId)) {
        _detectedMedia.addAll(_streamCache[newVideoId]!);
        notifyListeners();
        return;
      }

      // Auto-fetch streams in background (debounced for rapid navigation)
      if (newVideoId != null && _youtubeService.isValidYouTubeUrl(url)) {
        _fetchDebounceTimer?.cancel();
        _fetchDebounceTimer = Timer(const Duration(milliseconds: 200), () {
          _fetchYouTubeStreamsInternal(newVideoId);
        });
      }
    }

    if (!_isYouTubePage && _isSocialVideoPage) {
      _genericFetchDebounceTimer?.cancel();
      _genericFetchDebounceTimer = Timer(const Duration(milliseconds: 900), () {
        // Let the visible WebView capture resources first; headless fallback can run later.
        refreshCurrentPlatformMedia(
          forceRefresh: false,
          runHeadlessExtractor: false,
        );
      });
    }

    notifyListeners();
  }

  void setPageTitle(String title) {
    if (_tabs[_activeTabIndex].title == title) {
      return;
    }
    _tabs[_activeTabIndex].title = title;
    notifyListeners();
  }

  // --- Tab Management API ---
  void addNewTab({String url = 'https://google.com'}) {
    _tabs.add(BrowserTab(url: url));
    _activeTabIndex = _tabs.length - 1;
    _detectedMedia.clear();
    _fetchError = null;
    notifyListeners();
  }

  void switchTab(int index) {
    if (index >= 0 && index < _tabs.length && index != _activeTabIndex) {
      _activeTabIndex = index;
      _detectedMedia.clear();
      _fetchError = null;
      notifyListeners();
      // Need to re-trigger detect logic for the new active tab's URL
      setCurrentUrl(_tabs[_activeTabIndex].url);
    }
  }

  void closeTab(int index) {
    if (_tabs.length <= 1) {
      // Don't close last tab, just reset it
      _tabs[0] = BrowserTab(url: 'https://youtube.com');
      _detectedMedia.clear();
      notifyListeners();
      return;
    }

    _tabs.removeAt(index);
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    } else if (index < _activeTabIndex) {
      _activeTabIndex--;
    }

    _detectedMedia.clear();
    _fetchError = null;
    notifyListeners();
  }
  // --------------------------

  void setNavigationState({
    required bool canGoBack,
    required bool canGoForward,
  }) {
    if (_canGoBack == canGoBack && _canGoForward == canGoForward) {
      return;
    }
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    notifyListeners();
  }

  bool _isHttpMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  void _notifyMediaStateThrottled() {
    _resourceNotifyPending = true;

    if (_resourceNotifyTimer?.isActive ?? false) {
      return;
    }

    _resourceNotifyTimer = Timer(_resourceNotifyInterval, () {
      if (_resourceNotifyPending) {
        _resourceNotifyPending = false;
        notifyListeners();
      }
    });
  }

  bool _shouldInspectResource(String url, {String? contentType}) {
    final lowerUrl = url.toLowerCase();
    if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
      return false;
    }

    final lowerType = (contentType ?? '').toLowerCase();
    if (lowerType.contains('video/') ||
        lowerType.contains('audio/') ||
        lowerType.contains('mpegurl') ||
        lowerType.contains('dash+xml')) {
      return true;
    }

    return lowerUrl.contains('.mp4') ||
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('.mpd') ||
        lowerUrl.contains('.webm') ||
        lowerUrl.contains('.m4a') ||
        lowerUrl.contains('.mp3') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.contains('mime=video') ||
        lowerUrl.contains('content_type=video') ||
        lowerUrl.contains('bytestart=') ||
        lowerUrl.contains('byteend=') ||
        lowerUrl.contains('fbcdn.net') ||
        lowerUrl.contains('fbsbx.com') ||
        lowerUrl.contains('cdninstagram.com') ||
        lowerUrl.contains('video.twimg.com') ||
        lowerUrl.contains('twimg.com') ||
        lowerUrl.contains('tiktokcdn');
  }

  bool _shouldProcessResourceUrl(String url) {
    final dedupeKey = _resourceDedupeKey(url);
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastSeenAt = _recentResourceHits[dedupeKey];
    if (lastSeenAt != null && now - lastSeenAt < _resourceDedupWindowMs) {
      return false;
    }

    _recentResourceHits[dedupeKey] = now;
    _resourceHitInsertions++;

    if (_resourceHitInsertions % 80 == 0 ||
        _recentResourceHits.length > _maxRecentResourceEntries) {
      _recentResourceHits.removeWhere(
        (_, seenAt) => now - seenAt > _resourceDedupWindowMs,
      );
    }

    if (_recentResourceHits.length > _maxRecentResourceEntries) {
      if (_recentResourceHits.length > _maxRecentResourceEntries) {
        _recentResourceHits.remove(_recentResourceHits.keys.first);
      }
    }

    return true;
  }

  String _resourceDedupeKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return url;
    }

    final qpAll = <String, List<String>>{};
    uri.queryParametersAll.forEach((key, values) {
      if (_resourceDedupVolatileParams.contains(key.toLowerCase())) {
        return;
      }
      if (values.isNotEmpty) {
        qpAll[key] = List<String>.from(values);
      }
    });

    final normalizedQuery = <String, String>{};
    qpAll.forEach((key, values) {
      normalizedQuery[key] = values.last;
    });

    return uri
        .replace(
          queryParameters: normalizedQuery.isEmpty ? null : normalizedQuery,
          fragment: null,
        )
        .toString();
  }

  int? _extractSizeHint(String url) {
    try {
      final uri = Uri.parse(url);
      final qp = uri.queryParameters;

      int? parse(String key) {
        final v = qp[key];
        if (v == null || v.isEmpty) return null;
        return int.tryParse(v);
      }

      final explicit =
          parse('content_length') ??
          parse('clen') ??
          parse('filesize') ??
          parse('size');
      if (explicit != null && explicit > 0) return explicit;

      final start = parse('bytestart');
      final end = parse('byteend');
      if (start != null && end != null && end >= start) {
        return (end - start) + 1;
      }
    } catch (_) {}

    return null;
  }

  DetectedMedia _withCachedSize(DetectedMedia media) {
    if (media.fileSize != null && media.fileSize! > 0) {
      return media;
    }

    final cached = _resolvedSizeByUrl[media.url];
    if (cached == null || cached <= 0) {
      return media;
    }

    return media.copyWith(fileSize: cached);
  }

  Future<Map<String, dynamic>> _buildProbeHeaders(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return Map<String, dynamic>.from(DownloadService.defaultHeaders);
    }

    final host = uri.host.toLowerCase();

    String refererBase;
    if (host.contains('instagram.com') || host.contains('cdninstagram.com')) {
      refererBase = 'https://www.instagram.com/';
    } else if (host.contains('facebook.com') ||
        host.contains('fb.watch') ||
        host.contains('fbcdn.net') ||
        host.contains('fbsbx.com')) {
      refererBase = 'https://www.facebook.com/';
    } else if (host.contains('twitter.com') ||
        host.contains('x.com') ||
        host.contains('twimg.com')) {
      refererBase = 'https://x.com/';
    } else if (host.contains('tiktok.com') || host.contains('tiktokcdn')) {
      refererBase = 'https://www.tiktok.com/';
    } else {
      refererBase = '${uri.scheme}://${uri.host}/';
    }

    final refererUri = Uri.parse(refererBase);
    final headers = <String, dynamic>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Connection': 'keep-alive',
      'Referer': refererBase,
      'Origin': '${refererUri.scheme}://${refererUri.host}',
    };

    try {
      final cookieFragments = <String>[];

      final resourceCookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      if (resourceCookies.isNotEmpty) {
        cookieFragments.addAll(resourceCookies.map((c) => '${c.name}=${c.value}'));
      }

      final refererCookies = await CookieManager.instance().getCookies(
        url: WebUri(refererBase),
      );
      if (refererCookies.isNotEmpty) {
        cookieFragments.addAll(refererCookies.map((c) => '${c.name}=${c.value}'));
      }

      if (cookieFragments.isNotEmpty) {
        headers['Cookie'] = cookieFragments.toSet().join('; ');
      }
    } catch (e) {
      debugPrint('Size probe cookie attach failed for $host: $e');
    }

    return headers;
  }

  int? _extractContentLength(Headers headers) {
    int? parsePositiveInt(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      final value = int.tryParse(raw);
      if (value == null || value <= 0) return null;
      return value;
    }

    final directLength =
        parsePositiveInt(headers.value('content-length')) ??
        parsePositiveInt(headers.value('x-goog-stored-content-length')) ??
        parsePositiveInt(headers.value('x-amz-meta-content-length'));
    if (directLength != null) {
      return directLength;
    }

    final contentRange = headers.value('content-range');
    if (contentRange != null && contentRange.isNotEmpty) {
      final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
      if (match != null) {
        return parsePositiveInt(match.group(1));
      }
    }

    return null;
  }

  Future<int?> _probeMediaSize(String url) async {
    final headers = await _buildProbeHeaders(url);

    bool validStatus(int? code) {
      return code != null && code < 500;
    }

    try {
      final headResponse = await _metadataDio.head(
        url,
        options: Options(headers: headers, validateStatus: validStatus),
      );
      final length = _extractContentLength(headResponse.headers);
      if (length != null && length > 0) {
        return length;
      }
    } catch (_) {}

    try {
      final rangeHeaders = Map<String, dynamic>.from(headers)
        ..['Range'] = 'bytes=0-0';
      final response = await _metadataDio.get(
        url,
        options: Options(
          headers: rangeHeaders,
          responseType: ResponseType.bytes,
          validateStatus: validStatus,
        ),
      );
      final length = _extractContentLength(response.headers);
      if (length != null && length > 0) {
        return length;
      }
    } catch (_) {}

    return null;
  }

  void _applyResolvedSize(String url, int bytes) {
    if (bytes <= 0) return;

    var changed = false;
    for (var i = 0; i < _detectedMedia.length; i++) {
      final current = _detectedMedia[i];
      if (current.url != url) continue;
      if (current.fileSize != null && current.fileSize! > 0) continue;
      _detectedMedia[i] = current.copyWith(fileSize: bytes);
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  void _enqueueSizeProbeForMedia(DetectedMedia media) {
    if (media.fileSize != null && media.fileSize! > 0) {
      return;
    }

    final url = media.url;
    if (_resolvedSizeByUrl.containsKey(url)) {
      _applyResolvedSize(url, _resolvedSizeByUrl[url]!);
      return;
    }

    if (_sizeProbeInFlight.contains(url) || _sizeProbeQueue.contains(url)) {
      return;
    }

    _sizeProbeQueue.add(url);
    _pumpSizeProbeQueue();
  }

  void _pumpSizeProbeQueue() {
    if (_sizeProbePumpRunning) return;
    _sizeProbePumpRunning = true;

    unawaited(() async {
      try {
        while (_sizeProbeQueue.isNotEmpty) {
          final url = _sizeProbeQueue.removeFirst();
          if (_resolvedSizeByUrl.containsKey(url) || _sizeProbeInFlight.contains(url)) {
            continue;
          }

          _sizeProbeInFlight.add(url);
          try {
            final size = await _probeMediaSize(url);
            if (size != null && size > 0) {
              _resolvedSizeByUrl[url] = size;
              _applyResolvedSize(url, size);
            }
          } finally {
            _sizeProbeInFlight.remove(url);
          }
        }
      } finally {
        _sizeProbePumpRunning = false;
        if (_sizeProbeQueue.isNotEmpty) {
          _pumpSizeProbeQueue();
        }
      }
    }());
  }

  DetectedMedia _normalizeDetectedMedia(DetectedMedia media) {
    final uri = Uri.tryParse(media.url);
    if (uri == null || !uri.hasScheme) {
      return media;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return media;
    }

    final qpAll = <String, List<String>>{};
    uri.queryParametersAll.forEach((k, v) {
      qpAll[k] = List<String>.from(v);
    });

    var removedAny = false;
    for (final param in _volatileSegmentParams) {
      if (qpAll.remove(param) != null) {
        removedAny = true;
      }
    }

    final normalizedQuery = <String, String>{};
    qpAll.forEach((k, v) {
      if (v.isNotEmpty) {
        normalizedQuery[k] = v.last;
      }
    });

    final normalizedUrl = removedAny
        ? uri
              .replace(queryParameters: normalizedQuery.isEmpty ? null : normalizedQuery)
              .toString()
        : media.url;

    final sizeHint = media.fileSize ?? _extractSizeHint(media.url);

    final normalized = (normalizedUrl != media.url || sizeHint != media.fileSize)
        ? media.copyWith(url: normalizedUrl, fileSize: sizeHint)
        : media;

    return _withCachedSize(normalized);
  }

  String _mediaKey(DetectedMedia media) {
    final uri = Uri.tryParse(media.url);
    if (uri == null) return '${media.type.name}|${media.url}';

    final quality = (media.quality ?? '').toLowerCase();
    final qualityMatch = RegExp(r'(\d{3,4})p').firstMatch(quality);
    final qualityBucket = qualityMatch?.group(1) ?? (media.format ?? 'default');

    return '${media.type.name}|${uri.host}${uri.path}|$qualityBucket';
  }

  int _mediaScore(DetectedMedia media) {
    var score = media.fileSize ?? 0;
    final quality = (media.quality ?? '').toLowerCase();
    final qualityMatch = RegExp(r'(\d{3,4})p').firstMatch(quality);
    if (qualityMatch != null) {
      score += int.parse(qualityMatch.group(1)!) * 1024 * 1024;
    }
    if (media.isDash) {
      score -= 1024;
    }
    return score;
  }

  List<String> _buildExtractionCandidates(String rawUrl) {
    final normalized = ShareUrlService.normalizeSharedUrl(rawUrl) ?? rawUrl;
    final candidates = <String>[];

    void addIfValid(String candidate) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) return;

      final uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return;
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return;

      if (!candidates.contains(trimmed)) {
        candidates.add(trimmed);
      }
    }

    addIfValid(normalized);

    final uri = Uri.tryParse(normalized);
    if (uri == null) return candidates;

    final host = uri.host.toLowerCase();
    final isFacebook = host.contains('facebook.com') || host.contains('fb.watch');
    if (!isFacebook) return candidates;

    addIfValid(uri.replace(scheme: 'https', host: 'm.facebook.com').toString());
    addIfValid(uri.replace(scheme: 'https', host: 'www.facebook.com').toString());

    final watchId = uri.queryParameters['v'] ?? uri.queryParameters['video_id'];
    if (watchId != null && watchId.isNotEmpty) {
      addIfValid('https://m.facebook.com/watch/?v=$watchId');
    }

    return candidates;
  }

  bool _upsertDetectedMedia(DetectedMedia rawMedia) {
    final media = _normalizeDetectedMedia(rawMedia);
    if (!_isHttpMediaUrl(media.url)) return false;

    _enqueueSizeProbeForMedia(media);

    final key = _mediaKey(media);
    final existingIndex = _detectedMedia.indexWhere((m) => _mediaKey(m) == key);

    if (existingIndex != -1) {
      final current = _detectedMedia[existingIndex];
      final hasBetterScore = _mediaScore(media) > _mediaScore(current);
      final canFillMissingSize =
          (current.fileSize == null || current.fileSize! <= 0) &&
          (media.fileSize != null && media.fileSize! > 0);

      if (hasBetterScore || canFillMissingSize) {
        _detectedMedia[existingIndex] = media;
        return true;
      }
      return false;
    }

    if (_detectedMedia.length < _maxDetectedMediaItems) {
      _detectedMedia.add(media);
      return true;
    }

    var weakestIndex = 0;
    var weakestScore = _mediaScore(_detectedMedia[0]);
    for (var i = 1; i < _detectedMedia.length; i++) {
      final score = _mediaScore(_detectedMedia[i]);
      if (score < weakestScore) {
        weakestScore = score;
        weakestIndex = i;
      }
    }

    final candidateScore = _mediaScore(media);
    if (candidateScore > weakestScore) {
      _detectedMedia[weakestIndex] = media;
      return true;
    }

    return false;
  }

  /// Called when a resource is loaded - used for media detection
  void onResourceLoaded(String url, {String? contentType}) {
    if (!_isSocialVideoPage && !_isFetchingGeneric) {
      return;
    }

    if (_detectedMedia.length >= _maxDetectedMediaItems && !_isFetchingGeneric) {
      return;
    }

    if (_snifferService.isYouTubeUrl(_tabs[_activeTabIndex].url)) {
      return;
    }

    if (!_shouldInspectResource(url, contentType: contentType)) {
      return;
    }

    if (!_shouldProcessResourceUrl(url)) {
      return;
    }

    final media = _snifferService.detectMedia(
      url,
      pageTitle: pageTitle,
      contentType: contentType,
    );
    if (media != null) {
      final changed = _upsertDetectedMedia(media);
      if (changed) {
        _fetchError = null;
        _notifyMediaStateThrottled();
      }
    }
  }

  void addExtractedMediaUrls(List<String> urls, {String? titleHint}) {
    if (urls.isEmpty) return;

    var changedAny = false;

    for (final raw in urls) {
      final url = raw.trim();
      if (url.isEmpty) continue;

      final media = _snifferService.detectMedia(
        url,
        pageTitle: titleHint ?? pageTitle,
        contentType: 'video/mp4',
      );
      if (media == null) continue;

      final changed = _upsertDetectedMedia(media);
      if (changed) {
        _fetchError = null;
        changedAny = true;
      }
    }

    if (changedAny) {
      _notifyMediaStateThrottled();
    }
  }

  /// Internal fetch method - called automatically
  Future<void> _fetchYouTubeStreamsInternal(String videoId) async {
    if (_isFetchingYouTube) return;

    // Double-check cache
    if (_streamCache.containsKey(videoId)) {
      if (_currentYouTubeVideoId == videoId && _detectedMedia.isEmpty) {
        _detectedMedia.addAll(_streamCache[videoId]!);
        notifyListeners();
      }
      return;
    }

    _isFetchingYouTube = true;
    _fetchError = null;
    notifyListeners();

    try {
      final streams = await _youtubeService.getAvailableStreams(
        _tabs[_activeTabIndex].url,
      );

      // Cache immediately
      _streamCache[videoId] = List.from(streams);

      // Limit cache size
      while (_streamCache.length > _maxCacheSize) {
        _streamCache.remove(_streamCache.keys.first);
      }

      // Update UI if still on same video
      if (_currentYouTubeVideoId == videoId) {
        _detectedMedia.clear();
        _detectedMedia.addAll(streams);
        _fetchError = null;
      }
    } catch (e) {
      if (_currentYouTubeVideoId == videoId) {
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('timeout')) {
          _fetchError = 'Connection timed out. Tap refresh to try again.';
        } else if (errorMsg.contains('socket') ||
            errorMsg.contains('connection')) {
          _fetchError = 'Network error. Check your connection.';
        } else if (errorMsg.contains('bot') || errorMsg.contains('sign in')) {
          _fetchError = 'YouTube blocked the request. Try again later.';
        } else {
          _fetchError = 'Failed to load streams. Tap refresh to retry.';
        }
      }
    } finally {
      _isFetchingYouTube = false;
      notifyListeners();
    }
  }

  /// Fetch YouTube streams - public API for refresh button
  Future<void> fetchYouTubeStreams({bool forceRefresh = false}) async {
    if (!_isYouTubePage) return;

    final videoId = _currentYouTubeVideoId;
    if (videoId == null) return;

    // Check if it's a video page
    if (!_youtubeService.isValidYouTubeUrl(_tabs[_activeTabIndex].url)) {
      return;
    }

    // Force refresh - clear cache first
    if (forceRefresh) {
      _youtubeService.clearCache();
      _streamCache.remove(videoId);
    }

    // Use cache if available (and not force refreshing)
    if (!forceRefresh && _streamCache.containsKey(videoId)) {
      if (_detectedMedia.isEmpty) {
        _detectedMedia.addAll(_streamCache[videoId]!);
        notifyListeners();
      }
      return;
    }

    // Fetch using internal method
    await _fetchYouTubeStreamsInternal(videoId);
  }

  Future<void> refreshCurrentPlatformMedia({
    bool forceRefresh = false,
    bool runHeadlessExtractor = true,
  }) async {
    if (_isYouTubePage) {
      await fetchYouTubeStreams(forceRefresh: forceRefresh);
      return;
    }

    if (_isFetchingGeneric) return;

    _isFetchingGeneric = true;
    _fetchError = null;
    if (forceRefresh && runHeadlessExtractor) {
      _detectedMedia.clear();
    }
    notifyListeners();

    try {
      if (!runHeadlessExtractor) {
        return;
      }

      var foundAny = false;

      final candidates = _buildExtractionCandidates(_tabs[_activeTabIndex].url);
      for (var i = 0; i < candidates.length; i++) {
        final candidate = candidates[i];

        try {
          final extracted = await _webviewExtractor
              .extractMedia(candidate)
              .timeout(const Duration(seconds: 12));

          for (final media in extracted) {
            final changed = _upsertDetectedMedia(media);
            if (changed) {
              foundAny = true;
            }
          }

          if (_detectedMedia.isNotEmpty) {
            break;
          }
        } catch (e) {
          debugPrint('Headless extraction failed for a candidate URL: $e');
        }
      }

      if (foundAny) {
        _fetchError = null;
      }

      if (_detectedMedia.isEmpty) {
        _fetchError =
            'No downloadable media found. Play the video first, then tap refresh.';
      }
    } catch (e) {
      _fetchError = 'Failed to scan this page for media links.';
      debugPrint('Generic media refresh failed: $e');
    } finally {
      _isFetchingGeneric = false;
      notifyListeners();
    }
  }

  /// Clear detected media
  void clearDetectedMedia() {
    _detectedMedia.clear();
    notifyListeners();
  }

  /// Clear all state when navigating to a new page
  void onPageStarted(String url) {
    _detectedMedia.clear();
    _fetchError = null;
    _sizeProbeQueue.clear();
    _recentResourceHits.clear();
    _resourceHitInsertions = 0;
    _resourceNotifyTimer?.cancel();
    _resourceNotifyPending = false;
    _fetchDebounceTimer?.cancel();
    _genericFetchDebounceTimer?.cancel();
    setCurrentUrl(url);
    setLoading(true);
  }

  /// Called when page finishes loading
  void onPageFinished(String url) {
    setLoading(false);
    // Don't call setCurrentUrl here — onUpdateVisitedHistory handles it
    // Calling it again would trigger duplicate stream fetching
  }

  @override
  void dispose() {
    _fetchDebounceTimer?.cancel();
    _genericFetchDebounceTimer?.cancel();
    _resourceNotifyTimer?.cancel();
    _sizeProbeQueue.clear();
    _sizeProbeInFlight.clear();
    _recentResourceHits.clear();
    _resourceHitInsertions = 0;
    _metadataDio.close(force: true);
    _youtubeService.dispose();
    super.dispose();
  }
}
