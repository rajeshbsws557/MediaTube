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
  final String _homeUrl = 'https://m.youtube.com';
  bool _showHomePage = true; // Show home screen initially

  @override
  void initState() {
    super.initState();
    _urlController.text = _homeUrl;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

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
    
    setState(() {
      _showHomePage = false;
    });
    
    _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(url)),
    );
    _urlFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BrowserProvider>(
      builder: (context, browserProvider, _) {
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                // URL Bar (hide when showing home)
                if (!_showHomePage) _buildUrlBar(browserProvider),
                
                // Content area
                Expanded(
                  child: _showHomePage 
                      ? HomeScreen(onNavigate: _loadUrl)
                      : Stack(
                    children: [
                      RepaintBoundary(
                        child: InAppWebView(
                          initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
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
                            userAgent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                          ),
                          onWebViewCreated: (controller) {
                            _webViewController = controller;
                          },
                          onLoadStart: (controller, url) {
                            browserProvider.onPageStarted(url?.toString() ?? '');
                            _urlController.text = url?.toString() ?? '';
                          },
                          onLoadStop: (controller, url) async {
                            browserProvider.onPageFinished(url?.toString() ?? '');
                            
                            // Update navigation state
                            final canGoBack = await controller.canGoBack();
                            final canGoForward = await controller.canGoForward();
                          browserProvider.setNavigationState(
                            canGoBack: canGoBack,
                            canGoForward: canGoForward,
                          );
                        },
                        onTitleChanged: (controller, title) {
                          browserProvider.setPageTitle(title ?? '');
                        },
                        onLoadResource: (controller, resource) {
                          // Media sniffer - detect media URLs
                          final url = resource.url?.toString() ?? '';
                          if (url.isNotEmpty) {
                            browserProvider.onResourceLoaded(url);
                          }
                        },
                        onUpdateVisitedHistory: (controller, url, isReload) {
                          // Detect SPA navigation (YouTube uses this for video changes)
                          final urlStr = url?.toString() ?? '';
                          if (urlStr.isNotEmpty) {
                            browserProvider.setCurrentUrl(urlStr);
                            _urlController.text = urlStr;
                          }
                        },
                        onProgressChanged: (controller, progress) {
                          browserProvider.setLoading(progress < 100);
                        },
                      ),
                      ),
                      
                      // Loading indicator
                      if (browserProvider.isLoading)
                        const LinearProgressIndicator(),
                      
                      // Floating download button
                      if (browserProvider.hasDetectedMedia || browserProvider.isYouTubePage || browserProvider.hasFetchError)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingDownloadButton(
                            mediaCount: browserProvider.detectedMedia.length,
                            isYouTube: browserProvider.isYouTubePage,
                            isFetching: browserProvider.isFetchingYouTube,
                            hasError: browserProvider.hasFetchError,
                            onPressed: () => _showMediaSheet(context, browserProvider),
                          ),
                        ),
                    ],
                  ),
                ),
                
                // Bottom navigation bar
                _buildBottomBar(browserProvider),
              ],
            ),
          ),
        );
      },
    );
  }
  
  void _goHome() {
    setState(() {
      _showHomePage = true;
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
          // Downloads button - navigates to dedicated Downloads screen
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
          // Home button with highlight when on home
          Container(
            decoration: _showHomePage ? BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ) : null,
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
            icon: Icon(_showHomePage 
                ? Icons.refresh 
                : (browserProvider.isLoading ? Icons.close : Icons.refresh)),
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

  void _showMediaSheet(BuildContext context, BrowserProvider browserProvider) {
    // Show media selection sheet - streams are already cached from auto-fetch
    showModalBottomSheet(
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

/// Cached media sheet that uses BrowserProvider's cached streams
/// Shows instantly without re-fetching
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
          onRefresh: () => browserProvider.fetchYouTubeStreams(forceRefresh: true),
        );
      },
    );
  }
}
