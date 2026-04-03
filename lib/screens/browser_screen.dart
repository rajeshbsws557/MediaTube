import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../providers/providers.dart';
import '../services/services.dart';
import '../utils/utils.dart';
import '../widgets/widgets.dart';
import 'downloads_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();

  // Start with YouTube
  String _currentUrl = 'https://m.youtube.com';
  bool _showHomePage = true;

  // Track if WebView has ever been created (to avoid recreating it)
  bool _webViewEverCreated = false;

  // Flag to track if current session is from Share-to-Download
  bool _isShareToDownload = false;

  // Reactive listener for share-to-download intents
  BrowserProvider? _browserProviderRef;
  bool _isProcessingPendingUrl = false;
  bool _requestInterceptionEnabled = false;

  bool _shouldEnableRequestInterception(BrowserProvider provider) {
    return provider.shouldObserveNetworkMedia;
  }

  Future<void> _syncRequestInterceptionMode(
    BrowserProvider provider, {
    bool force = false,
  }) async {
    final shouldEnable = _shouldEnableRequestInterception(provider);
    if (!force && _requestInterceptionEnabled == shouldEnable) {
      return;
    }

    _requestInterceptionEnabled = shouldEnable;
    final controller = _webViewController;
    if (controller == null) {
      return;
    }

    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          useShouldInterceptRequest: shouldEnable,
        ),
      );
    } catch (e) {
      debugPrint('Failed to toggle request interception: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlController.text = _currentUrl;

    // Set up reactive listener for share-to-download intents
    // and preload WebView after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _browserProviderRef = Provider.of<BrowserProvider>(
        context,
        listen: false,
      );
      _browserProviderRef!.addListener(_checkAndProcessPendingUrl);
      // Check immediately in case a URL was set before listener attached
      _checkAndProcessPendingUrl();

      // Preload WebView after a short delay to prevent UI freeze
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_webViewEverCreated) {
          setState(() {
            _webViewEverCreated = true;
          });
        }
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _browserProviderRef?.removeListener(_checkAndProcessPendingUrl);
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardForMedia();
    }
  }

  Future<void> _checkClipboardForMedia() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim() ?? '';

      final urlRegex = RegExp(r'https?://[^\s]+');
      final match = urlRegex.firstMatch(text);
      if (match == null) return;

      String url = match.group(0)!;
      url = url.replaceAll(RegExp(r'[.,!?;:]+$'), '');

      final ytService = YouTubeService();
      if (!ytService.isValidYouTubeUrl(url)) return;

      if (!mounted) return;
      final downloadProvider = context.read<DownloadProvider>();

      // Check if already in active/history
      final exists =
          downloadProvider.allDownloadsHistory.any((task) => task.url == url) ||
          downloadProvider.activeDownloads.any((task) => task.url == url);

      if (exists || _currentUrl == url) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('YouTube link detected in clipboard.'),
          action: SnackBarAction(
            label: 'Load',
            onPressed: () {
              _loadUrl(url);
              _processPendingUrl(url);
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      debugPrint('Clipboard check error: $e');
    }
  }

  /// Reactively checks for and processes pending share-to-download URLs.
  /// Called whenever BrowserProvider notifies listeners.
  void _checkAndProcessPendingUrl() {
    if (!mounted || _isProcessingPendingUrl) return;
    final provider = _browserProviderRef;
    if (provider == null) return;
    final pendingUrl = provider.pendingUrl;
    if (pendingUrl == null) return;

    // Consume immediately to prevent re-processing
    provider.consumePendingUrl();
    _processPendingUrl(pendingUrl);
  }

  /// Processes a shared URL: pops any routes on top, fetches streams,
  /// shows media sheet, then navigates to Downloads.
  Future<void> _processPendingUrl(String url) async {
    _isProcessingPendingUrl = true;
    try {
      final normalized = ShareUrlService.normalizeSharedUrl(url) ?? url;
      if (!ShareUrlService.isSupportedWebUrl(normalized)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This shared link cannot be opened directly. Share a web URL from Facebook.',
              ),
            ),
          );
        }
        return;
      }

      // Pop any routes on top (DownloadsScreen, bottom sheets) so we're
      // back on BrowserScreen before showing the new media sheet.
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }

      // Small delay to let the pop animation settle
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;

      setState(() => _isShareToDownload = true);

      final browserProvider = Provider.of<BrowserProvider>(
        context,
        listen: false,
      );

      // Trigger detection for the shared URL.
      // For non-YouTube platforms this must load the page in WebView first.
      _loadUrl(normalized);
      browserProvider.setCurrentUrl(normalized);
      _currentUrl = normalized;

      // Start extraction immediately so shared links do not require manual retries.
      unawaited(
        browserProvider.refreshCurrentPlatformMedia(
          forceRefresh: true,
          runHeadlessExtractor: true,
        ),
      );

      // Retry once automatically if no streams are found from the first pass.
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        if (browserProvider.hasDetectedMedia || browserProvider.isFetchingMedia) {
          return;
        }
        unawaited(
          browserProvider.refreshCurrentPlatformMedia(
            forceRefresh: false,
            runHeadlessExtractor: true,
          ),
        );
      });

      // Give the fetch a moment to start so the sheet shows loading state
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;

      // Show the media selection sheet
      await _showMediaSheet(context, browserProvider);

      // After sheet closes, navigate to Downloads screen or exit if share
      if (_isShareToDownload && mounted) {
        setState(() => _isShareToDownload = false);

        final hasActive = Provider.of<DownloadProvider>(
          context,
          listen: false,
        ).hasActiveDownloads;
        if (hasActive) {
          // A download was started via share! Pop back to previous app.
          try {
            const platform = MethodChannel('com.rajesh.mediatube/app');
            await platform.invokeMethod('moveToBackground');
          } catch (_) {
            SystemNavigator.pop();
          }
        } else {
          // User probably cancelled, stay in app or pop?
          // We'll just stay in app for safety.
        }
      }
    } finally {
      _isProcessingPendingUrl = false;
      // Re-check in case more URLs were queued while we were processing
      if (mounted) {
        _checkAndProcessPendingUrl();
      }
    }
  }

  bool _isWebViewReady = false; // Tracks if WebView is fully created
  bool _isUrlBarVisible = true;
  int _lastScrollY = 0;

  void _loadUrl(String url) {
    if (url.isEmpty) return;

    final normalizedUrl = UrlInputSanitizer.sanitizeToNavigableUrl(url);
    if (normalizedUrl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only valid http/https URLs are allowed.')),
      );
      return;
    }

    _currentUrl = normalizedUrl;

    if (_showHomePage) {
      // 1. IMMEDIATE UI UPDATE: Switch to WebView mode
      setState(() {
        _showHomePage = false;
        _webViewEverCreated = true;
      });

      // 2. DEFERRED LOAD: Allow the UI to render the WebView container first
      // This prevents the "freeze" because the main thread isn't blocked by generic initialization
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_isWebViewReady && mounted) {
          _webViewController?.loadUrl(
            urlRequest: URLRequest(url: WebUri(normalizedUrl)),
          );
        }
      });
    } else if (_isWebViewReady) {
      // WebView already exists and is ready
      _webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(normalizedUrl)),
      );
    }
    // If WebView is being created but not ready yet, _currentUrl is already
    // set and will be used as initialUrlRequest

    _urlFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // pendingUrl is now handled reactively via _checkAndProcessPendingUrl listener

    return Scaffold(
      bottomNavigationBar: Selector<
        BrowserProvider,
        ({bool canGoBack, bool canGoForward, bool isLoading})
      >(
        selector: (_, provider) => (
          canGoBack: provider.canGoBack,
          canGoForward: provider.canGoForward,
          isLoading: provider.isLoading,
        ),
        builder: (context, navState, _) => _buildNavigationBar(
          canGoBack: navState.canGoBack,
          canGoForward: navState.canGoForward,
          isLoading: navState.isLoading,
        ),
      ),
      body: Stack(
        children: [
          // Main content
          SafeArea(
            child: Column(
              children: [
                // URL Bar (hide when showing home)
                if (!_showHomePage)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: _isUrlBarVisible ? 64.0 : 0.0,
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Selector<
                        BrowserProvider,
                        ({String currentUrl, int tabCount})
                      >(
                        selector: (_, provider) => (
                          currentUrl: provider.currentUrl,
                          tabCount: provider.tabs.length,
                        ),
                        builder: (context, data, _) => _buildUrlBar(
                          currentUrl: data.currentUrl,
                          tabCount: data.tabCount,
                        ),
                      ),
                    ),
                  ),

                // Content area
                Expanded(
                  child: Stack(
                    children: [
                      // Keep WebView alive but hidden when on home
                      if (_webViewEverCreated)
                        Offstage(
                          offstage: _showHomePage,
                          child: _buildWebView(),
                        ),
                      // Home screen overlay
                      if (_showHomePage) HomeScreen(onNavigate: _loadUrl),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    return Stack(
      children: [
        RepaintBoundary(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: false,
              supportMultipleWindows: false,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              useShouldInterceptRequest: _requestInterceptionEnabled,
              useWideViewPort: true,
              loadWithOverviewMode: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              safeBrowsingEnabled: true,
              allowFileAccess: false,
              allowContentAccess: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
              // Performance optimizations
              cacheEnabled: true,
              cacheMode: CacheMode.LOAD_DEFAULT,
              hardwareAcceleration: true,
              thirdPartyCookiesEnabled: true,
              userAgent:
                  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            ),
            onScrollChanged: (controller, x, y) {
              if (y > _lastScrollY && y > 100) {
                // Scrolling down, aggressively hide past 100px
                if (_isUrlBarVisible) {
                  setState(() => _isUrlBarVisible = false);
                }
              } else if (y < _lastScrollY || y < 50) {
                // Scrolling up or near top, show
                if (!_isUrlBarVisible) {
                  setState(() => _isUrlBarVisible = true);
                }
              }
              _lastScrollY = y;
            },
            onWebViewCreated: (controller) {
              _webViewController = controller;
              _isWebViewReady = true;

              final provider = context.read<BrowserProvider>();
              unawaited(_syncRequestInterceptionMode(provider, force: true));
            },
            onLoadStart: (controller, url) {
              final provider = context.read<BrowserProvider>();
              provider.setLoading(true);
              unawaited(_syncRequestInterceptionMode(provider));
              _urlController.text = url?.toString() ?? '';
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final rawUrl = navigationAction.request.url?.toString() ?? '';
              if (rawUrl.isEmpty) {
                return NavigationActionPolicy.ALLOW;
              }

              final uri = Uri.tryParse(rawUrl);
              final scheme = uri?.scheme.toLowerCase();
              if (scheme == 'http' || scheme == 'https') {
                if (uri == null || uri.host.isEmpty) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              }

              if (scheme == null) {
                return NavigationActionPolicy.CANCEL;
              }

              final normalizedUrl = ShareUrlService.normalizeSharedUrl(rawUrl);
              if (normalizedUrl != null &&
                  ShareUrlService.isSupportedWebUrl(normalizedUrl) &&
                  UrlInputSanitizer.isHttpOrHttpsUrl(normalizedUrl)) {
                controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(normalizedUrl)),
                );
              }

              return NavigationActionPolicy.CANCEL;
            },
            onLoadStop: (controller, url) async {
              final provider = context.read<BrowserProvider>();
              provider.setLoading(false);

              // For non-YouTube platforms, run a quick DOM scan for media URLs
              // because many platforms hide direct links behind dynamic scripts.
              try {
                if (!provider.isYouTubePage) {
                  final result = await controller.evaluateJavascript(
                    source: '''
                      (function() {
                        var urls = [];
                        function pushIfValid(u) {
                          if (!u || typeof u !== 'string') return;
                          if (u.startsWith('http')) urls.push(u);
                        }

                        var videos = document.getElementsByTagName('video');
                        for (var i = 0; i < videos.length; i++) {
                          pushIfValid(videos[i].src);
                          pushIfValid(videos[i].currentSrc);
                          var sources = videos[i].getElementsByTagName('source');
                          for (var j = 0; j < sources.length; j++) {
                            pushIfValid(sources[j].src);
                          }
                        }

                        var metas = document.getElementsByTagName('meta');
                        for (var k = 0; k < metas.length; k++) {
                          var p = (metas[k].getAttribute('property') || '').toLowerCase();
                          if (p === 'og:video' || p === 'og:video:url' || p === 'og:video:secure_url') {
                            pushIfValid(metas[k].getAttribute('content'));
                          }
                        }

                        return Array.from(new Set(urls));
                      })();
                    ''',
                  );

                  if (result is List) {
                    provider.addExtractedMediaUrls(
                      result.map((e) => e.toString()).toList(),
                    );
                  }

                  if (provider.isSocialVideoPage &&
                      !provider.hasDetectedMedia &&
                      !provider.isFetchingMedia) {
                    provider.refreshCurrentPlatformMedia(
                      forceRefresh: false,
                      runHeadlessExtractor: true,
                    );
                  }
                }
              } catch (e) {
                debugPrint('DOM media scan failed: $e');
              }

              // Update navigation state
              final canGoBack = await controller.canGoBack();
              final canGoForward = await controller.canGoForward();
              provider.setNavigationState(
                canGoBack: canGoBack,
                canGoForward: canGoForward,
              );

              unawaited(_syncRequestInterceptionMode(provider));
            },
            onTitleChanged: (controller, title) {
              context.read<BrowserProvider>().setPageTitle(title ?? '');
            },
            onLoadResource: (controller, resource) {
              final provider = context.read<BrowserProvider>();
              if (!provider.shouldObserveNetworkMedia) {
                return;
              }

              final dynamic raw = resource;
              final url = raw.url?.toString() ?? '';
              if (url.isEmpty) {
                return;
              }

              String? contentTypeHint;
              int? contentLengthHint;

              try {
                final dynamic typeValue = raw.contentType;
                if (typeValue is String && typeValue.isNotEmpty) {
                  contentTypeHint = typeValue;
                }
              } catch (_) {}

              try {
                final dynamic lengthValue = raw.contentLength;
                if (lengthValue is int && lengthValue > 0) {
                  contentLengthHint = lengthValue;
                } else if (lengthValue is String) {
                  final parsed = int.tryParse(lengthValue);
                  if (parsed != null && parsed > 0) {
                    contentLengthHint = parsed;
                  }
                }
              } catch (_) {}

              try {
                final dynamic responseHeaders = raw.responseHeaders;
                if (responseHeaders is Map) {
                  String? lookupHeader(String key) {
                    final lowerKey = key.toLowerCase();
                    for (final entry in responseHeaders.entries) {
                      final headerKey = entry.key.toString().toLowerCase();
                      if (headerKey == lowerKey) {
                        return entry.value?.toString();
                      }
                    }
                    return null;
                  }

                  contentTypeHint ??= lookupHeader('content-type');

                  final lengthFromHeader = lookupHeader('content-length');
                  if (contentLengthHint == null &&
                      lengthFromHeader != null &&
                      lengthFromHeader.isNotEmpty) {
                    final parsed = int.tryParse(lengthFromHeader);
                    if (parsed != null && parsed > 0) {
                      contentLengthHint = parsed;
                    }
                  }
                }
              } catch (_) {}

              provider.onResourceLoaded(
                url,
                contentType: contentTypeHint,
                contentLength: contentLengthHint,
              );
            },
            shouldInterceptRequest: (controller, request) async {
              final provider = context.read<BrowserProvider>();
              if (!provider.shouldObserveNetworkMedia) {
                return null;
              }

              final url = request.url.toString();
              if (url.isEmpty) return null;

              String? contentTypeHint;
              final acceptHeader = request.headers?['Accept'] ?? request.headers?['accept'];
              if (acceptHeader != null && acceptHeader.isNotEmpty) {
                contentTypeHint = acceptHeader;
              }

              final fetchDest = request.headers?['Sec-Fetch-Dest'] ??
                  request.headers?['sec-fetch-dest'];
              if (fetchDest == 'video') {
                contentTypeHint = 'video/mp4';
              } else if (fetchDest == 'audio') {
                contentTypeHint = 'audio/mpeg';
              }

              provider.onResourceLoaded(url, contentType: contentTypeHint);

              return null;
            },
            onUpdateVisitedHistory: (controller, url, isReload) {
              final urlStr = url?.toString() ?? '';
              if (urlStr.isNotEmpty) {
                final provider = context.read<BrowserProvider>();
                provider.setCurrentUrl(urlStr);
                unawaited(_syncRequestInterceptionMode(provider));
                _urlController.text = urlStr;
              }
            },
            onProgressChanged: (controller, progress) {
              context.read<BrowserProvider>().setLoading(progress < 100);
            },
          ),
        ),

        // Loading indicator - Rebuilds ONLY when isLoading changes
        Selector<BrowserProvider, bool>(
          selector: (_, provider) => provider.isLoading,
          builder: (context, isLoading, child) => isLoading
              ? const LinearProgressIndicator()
              : const SizedBox.shrink(),
        ),

        // Floating download button - only rebuild on button-relevant state
        Selector<
          BrowserProvider,
          ({
            bool hasDetectedMedia,
            bool isYouTubePage,
            bool hasFetchError,
            int mediaCount,
            bool isFetchingMedia,
          })
        >(
          selector: (_, browserProvider) => (
            hasDetectedMedia: browserProvider.hasDetectedMedia,
            isYouTubePage: browserProvider.isYouTubePage,
            hasFetchError: browserProvider.hasFetchError,
            mediaCount: browserProvider.detectedMedia.length,
            isFetchingMedia: browserProvider.isFetchingMedia,
          ),
          builder: (context, state, _) {
            if (state.hasDetectedMedia ||
                state.isYouTubePage ||
                state.hasFetchError) {
              return Positioned(
                right: 16,
                bottom: 16,
                child: FloatingDownloadButton(
                  mediaCount: state.mediaCount,
                  isYouTube: state.isYouTubePage,
                  isFetching: state.isFetchingMedia,
                  hasError: state.hasFetchError,
                  onPressed: () => _showMediaSheet(
                    context,
                    context.read<BrowserProvider>(),
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  void _goHome() {
    setState(() {
      _showHomePage = true;
      // Don't destroy WebView — keep it alive offstage for instant return
    });
    _urlController.text = '';
  }

  Widget _buildUrlBar({
    required String currentUrl,
    required int tabCount,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    currentUrl.startsWith('https')
                        ? Icons.lock
                        : Icons.language,
                    size: 18,
                    color: currentUrl.startsWith('https')
                        ? Colors.green
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Search or enter URL',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _loadUrl,
                    ),
                  ),
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _urlController.clear();
                        _urlFocusNode.requestFocus();
                      },
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Tabs Button
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.filter_none),
                onPressed: () =>
                    _showTabsSheet(context, context.read<BrowserProvider>()),
              ),
              Positioned(
                child: IgnorePointer(
                  child: Text(
                    '$tabCount',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showTabsSheet(BuildContext context, BrowserProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tabs (${provider.tabs.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          provider.addNewTab();
                          Navigator.pop(context);
                          _loadUrl('https://google.com'); // load default
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Consumer<BrowserProvider>(
                    builder: (context, currentProvider, _) {
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: currentProvider.tabs.length,
                        itemBuilder: (context, index) {
                          final tab = currentProvider.tabs[index];
                          final isActive =
                              index == currentProvider.activeTabIndex;
                          return ListTile(
                            leading: Icon(
                              Icons.public,
                              color: isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              tab.title.isEmpty ? tab.url : tab.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isActive
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                            subtitle: Text(
                              tab.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                currentProvider.closeTab(index);
                                if (currentProvider.tabs.isEmpty) {
                                  Navigator.pop(context);
                                }
                              },
                            ),
                            onTap: () {
                              currentProvider.switchTab(index);
                              Navigator.pop(context);
                              _loadUrl(
                                currentProvider.currentUrl,
                              ); // re-trigger load for context
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildNavigationBar({
    required bool canGoBack,
    required bool canGoForward,
    required bool isLoading,
  }) {
    // Current "selected" index logic based on state
    int selectedIndex = _showHomePage
        ? 2
        : 0; // Default to Home or just a generic unselected state if possible

    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: (int index) {
        switch (index) {
          case 0:
            if (!_showHomePage && canGoBack) {
              _webViewController?.goBack();
            }
            break;
          case 1:
            if (!_showHomePage && canGoForward) {
              _webViewController?.goForward();
            }
            break;
          case 2:
            _goHome();
            break;
          case 3:
            if (!_showHomePage) {
              if (isLoading) {
                _webViewController?.stopLoading();
              } else {
                _webViewController?.reload();
              }
            }
            break;
          case 4:
            _openDownloadsScreen(context);
            break;
        }
      },
      destinations: [
        NavigationDestination(
          icon: Icon(
            Icons.arrow_back,
            color: (!_showHomePage && canGoBack)
                ? null
                : Theme.of(context).disabledColor,
          ),
          label: 'Back',
        ),
        NavigationDestination(
          icon: Icon(
            Icons.arrow_forward,
            color: (!_showHomePage && canGoForward)
                ? null
                : Theme.of(context).disabledColor,
          ),
          label: 'Forward',
        ),
        NavigationDestination(
          icon: Icon(
            Icons.home,
            color: _showHomePage ? Theme.of(context).colorScheme.primary : null,
          ),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(
            _showHomePage
                ? Icons.refresh
                : (isLoading ? Icons.close : Icons.refresh),
            color: _showHomePage ? Theme.of(context).disabledColor : null,
          ),
          label: isLoading ? 'Stop' : 'Refresh',
        ),
        NavigationDestination(
          icon: Stack(
            children: [
              const Icon(Icons.download),
              Consumer<DownloadProvider>(
                builder: (context, downloadProvider, _) {
                  if (downloadProvider.hasActiveDownloads) {
                    return Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
          label: 'Downloads',
        ),
      ],
    );
  }

  Future<void> _showMediaSheet(
    BuildContext context,
    BrowserProvider browserProvider,
  ) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ChangeNotifierProvider.value(
        value: browserProvider,
        child: const _CachedMediaSheet(),
      ),
    );
  }

  void _openDownloadsScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DownloadsScreen()),
    );
  }
}

class _CachedMediaSheet extends StatelessWidget {
  const _CachedMediaSheet();

  @override
  Widget build(BuildContext context) {
    return Consumer<BrowserProvider>(
      builder: (context, browserProvider, _) {
        return MediaSelectionSheet(
          media: browserProvider.detectedMedia,
          isYouTube: browserProvider.isYouTubePage,
          isFetching: browserProvider.isFetchingMedia,
          errorMessage: browserProvider.fetchError,
          onRefresh: () =>
              browserProvider.refreshCurrentPlatformMedia(forceRefresh: true),
        );
      },
    );
  }
}
