import 'package:flutter/foundation.dart';
import 'dart:async';
import '../models/models.dart';
import '../services/services.dart';

/// Provider for managing media detection and browser state
/// Optimized for instant stream loading with aggressive caching
class BrowserProvider extends ChangeNotifier {
  final MediaSnifferService _snifferService = MediaSnifferService();
  final YouTubeService _youtubeService = YouTubeService();

  String _currentUrl = '';
  String _pageTitle = '';
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  // Detected media
  final List<DetectedMedia> _detectedMedia = [];
  bool _isYouTubePage = false;
  bool _isFetchingYouTube = false;
  String? _fetchError;

  // Track current YouTube video to detect navigation within YouTube
  String? _currentYouTubeVideoId;

  // Debounce timer for stream fetching
  Timer? _fetchDebounceTimer;

  // PERSISTENT cache - survives sheet open/close, holds multiple videos
  static final Map<String, List<DetectedMedia>> _streamCache = {};
  static const int _maxCacheSize = 50; // Increased cache for more videos

  // Share Intent Support - queue to handle rapid successive shares
  final List<String> _pendingUrls = [];

  // Getters
  String get currentUrl => _currentUrl;
  String get pageTitle => _pageTitle;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  List<DetectedMedia> get detectedMedia => List.unmodifiable(_detectedMedia);
  bool get hasDetectedMedia => _detectedMedia.isNotEmpty;
  bool get isYouTubePage => _isYouTubePage;
  bool get isFetchingYouTube => _isFetchingYouTube;
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
    _isLoading = loading;
    notifyListeners();
  }

  void setCurrentUrl(String url) {
    // Skip if URL hasn't changed (prevents redundant processing from
    // multiple WebView callbacks firing for the same navigation)
    if (url == _currentUrl) return;

    _currentUrl = url;

    // Check if this is a YouTube page
    final wasYouTube = _isYouTubePage;
    _isYouTubePage = _snifferService.isYouTubeUrl(url);

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

    notifyListeners();
  }

  void setPageTitle(String title) {
    _pageTitle = title;
    notifyListeners();
  }

  void setNavigationState({
    required bool canGoBack,
    required bool canGoForward,
  }) {
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    notifyListeners();
  }

  /// Called when a resource is loaded - used for media detection
  void onResourceLoaded(String url) {
    // Don't sniff YouTube URLs - we use youtube_explode instead
    if (_snifferService.isYouTubeUrl(_currentUrl)) {
      return;
    }

    final media = _snifferService.detectMedia(url, pageTitle: _pageTitle);
    if (media != null) {
      // Check if we already have this URL
      final exists = _detectedMedia.any((m) => m.url == media.url);
      if (!exists) {
        _detectedMedia.add(media);
        notifyListeners();
      }
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
      final streams = await _youtubeService.getAvailableStreams(_currentUrl);

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
    if (!_youtubeService.isValidYouTubeUrl(_currentUrl)) {
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

  /// Clear detected media
  void clearDetectedMedia() {
    _detectedMedia.clear();
    notifyListeners();
  }

  /// Clear all state when navigating to a new page
  void onPageStarted(String url) {
    _detectedMedia.clear();
    _fetchError = null;
    _fetchDebounceTimer?.cancel();
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
    _youtubeService.dispose();
    super.dispose();
  }
}
