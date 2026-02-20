import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../widgets/widgets.dart';
import 'downloads_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
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

  @override
  void initState() {
    super.initState();
    _urlController.text = _currentUrl;

    // Set up reactive listener for share-to-download intents
    // and preload WebView after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _browserProviderRef = Provider.of<BrowserProvider>(context, listen: false);
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
    _browserProviderRef?.removeListener(_checkAndProcessPendingUrl);
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
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
      // Pop any routes on top (DownloadsScreen, bottom sheets) so we're
      // back on BrowserScreen before showing the new media sheet.
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }

      // Small delay to let the pop animation settle
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;

      setState(() => _isShareToDownload = true);

      final browserProvider =
          Provider.of<BrowserProvider>(context, listen: false);

      // Trigger stream detection for the shared URL
      browserProvider.setCurrentUrl(url);
      _currentUrl = url;
      browserProvider.fetchYouTubeStreams(forceRefresh: true);

      // Give the fetch a moment to start so the sheet shows loading state
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;

      // Show the media selection sheet
      await _showMediaSheet(context, browserProvider);

      // After sheet closes, navigate to Downloads screen
      if (_isShareToDownload && mounted) {
        setState(() => _isShareToDownload = false);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const DownloadsScreen()),
        );
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

  void _loadUrl(String url) {
    if (url.isEmpty) return;

    // Add https:// if no protocol specified
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // Check if it looks like a URL or search query
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        // Treat as search query
        url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
      }
    }

    _currentUrl = url;

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
          _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        }
      });
    } else if (_isWebViewReady) {
      // WebView already exists and is ready
      _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
    // If WebView is being created but not ready yet, _currentUrl is already
    // set and will be used as initialUrlRequest

    _urlFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // pendingUrl is now handled reactively via _checkAndProcessPendingUrl listener

    return Scaffold(
      body: Stack(
        children: [
          // Main content
          SafeArea(
            child: Column(
              children: [
                // URL Bar (hide when showing home)
                if (!_showHomePage)
                  Consumer<BrowserProvider>(
                    builder: (context, provider, _) => _buildUrlBar(provider),
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

                // Bottom navigation bar
                Consumer<BrowserProvider>(
                  builder: (context, provider, _) => _buildBottomBar(provider),
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
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              useWideViewPort: true,
              loadWithOverviewMode: true,
              domStorageEnabled: true,
              databaseEnabled: true,
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
            onWebViewCreated: (controller) {
              _webViewController = controller;
              _isWebViewReady = true;
            },
            onLoadStart: (controller, url) {
              Provider.of<BrowserProvider>(
                context,
                listen: false,
              ).setLoading(true);
              _urlController.text = url?.toString() ?? '';
            },
            onLoadStop: (controller, url) async {
              final provider = Provider.of<BrowserProvider>(
                context,
                listen: false,
              );
              provider.setLoading(false);

              // Update navigation state
              final canGoBack = await controller.canGoBack();
              final canGoForward = await controller.canGoForward();
              provider.setNavigationState(
                canGoBack: canGoBack,
                canGoForward: canGoForward,
              );
            },
            onTitleChanged: (controller, title) {
              Provider.of<BrowserProvider>(
                context,
                listen: false,
              ).setPageTitle(title ?? '');
            },
            onLoadResource: (controller, resource) {
              final url = resource.url?.toString() ?? '';
              if (url.isNotEmpty) {
                Provider.of<BrowserProvider>(
                  context,
                  listen: false,
                ).onResourceLoaded(url);
              }
            },
            onUpdateVisitedHistory: (controller, url, isReload) {
              final urlStr = url?.toString() ?? '';
              if (urlStr.isNotEmpty) {
                Provider.of<BrowserProvider>(
                  context,
                  listen: false,
                ).setCurrentUrl(urlStr);
                _urlController.text = urlStr;
              }
            },
            onProgressChanged: (controller, progress) {
              Provider.of<BrowserProvider>(
                context,
                listen: false,
              ).setLoading(progress < 100);
            },
          ),
        ),

        // Loading indicator - Rebuilds ONLY when isLoading changes
        Selector<BrowserProvider, bool>(
          selector: (_, provider) => provider.isLoading,
          builder: (_, isLoading, __) => isLoading
              ? const LinearProgressIndicator()
              : const SizedBox.shrink(),
        ),

        // Floating download button - Rebuilds when media detection state changes
        Consumer<BrowserProvider>(
          builder: (context, browserProvider, _) {
            if (browserProvider.hasDetectedMedia ||
                browserProvider.isYouTubePage ||
                browserProvider.hasFetchError) {
              return Positioned(
                right: 16,
                bottom: 16,
                child: FloatingDownloadButton(
                  mediaCount: browserProvider.detectedMedia.length,
                  isYouTube: browserProvider.isYouTubePage,
                  isFetching: browserProvider.isFetchingYouTube,
                  hasError: browserProvider.hasFetchError,
                  onPressed: () => _showMediaSheet(context, browserProvider),
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

  Widget _buildUrlBar(BrowserProvider browserProvider) {
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
                    browserProvider.currentUrl.startsWith('https')
                        ? Icons.lock
                        : Icons.language,
                    size: 18,
                    color: browserProvider.currentUrl.startsWith('https')
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
          // Downloads button
          IconButton(
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
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 12,
                            minHeight: 12,
                          ),
                          child: Text(
                            '${downloadProvider.activeDownloads.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            onPressed: () => _openDownloadsScreen(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BrowserProvider browserProvider) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: (_showHomePage || !browserProvider.canGoBack)
                ? null
                : () => _webViewController?.goBack(),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: (_showHomePage || !browserProvider.canGoForward)
                ? null
                : () => _webViewController?.goForward(),
          ),
          Container(
            decoration: _showHomePage
                ? BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  )
                : null,
            child: IconButton(
              icon: Icon(
                Icons.home,
                color: _showHomePage
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _goHome,
            ),
          ),
          IconButton(
            icon: Icon(
              _showHomePage
                  ? Icons.refresh
                  : (browserProvider.isLoading ? Icons.close : Icons.refresh),
            ),
            onPressed: _showHomePage
                ? null
                : () {
                    if (browserProvider.isLoading) {
                      _webViewController?.stopLoading();
                    } else {
                      _webViewController?.reload();
                    }
                  },
          ),
          IconButton(
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
            onPressed: () => _openDownloadsScreen(context),
          ),
        ],
      ),
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
          isFetching: browserProvider.isFetchingYouTube,
          errorMessage: browserProvider.fetchError,
          onRefresh: () =>
              browserProvider.fetchYouTubeStreams(forceRefresh: true),
        );
      },
    );
  }
}
