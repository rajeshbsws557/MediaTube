import 'dart:math';

/// Simple unique ID generator without external dependency.
String _generateTabId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(99999);
  return '${now}_$rand';
}

class BrowserTab {
  final String id;
  String url;
  String title;
  String? faviconUrl;
  DateTime lastVisitedAt;
  List<String> history;
  int historyIndex;

  BrowserTab({
    String? id,
    required this.url,
    this.title = 'New Tab',
    this.faviconUrl,
    DateTime? lastVisitedAt,
    List<String>? history,
    int? historyIndex,
  })  : id = id ?? _generateTabId(),
        lastVisitedAt = lastVisitedAt ?? DateTime.now(),
        history = history ?? [url],
        historyIndex = historyIndex ?? 0;

  BrowserTab copyWith({
    String? id,
    String? url,
    String? title,
    String? faviconUrl,
    DateTime? lastVisitedAt,
    List<String>? history,
    int? historyIndex,
  }) {
    return BrowserTab(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      lastVisitedAt: lastVisitedAt ?? this.lastVisitedAt,
      history: history ?? List<String>.from(this.history),
      historyIndex: historyIndex ?? this.historyIndex,
    );
  }

  /// Navigate to a new URL within this tab's history stack.
  /// Truncates forward history if we're not at the end.
  void navigateTo(String newUrl) {
    if (newUrl == url) return;

    // Truncate any forward history
    if (historyIndex < history.length - 1) {
      history.removeRange(historyIndex + 1, history.length);
    }

    history.add(newUrl);

    // Keep history bounded to 50 entries
    if (history.length > 50) {
      history.removeAt(0);
    } else {
      historyIndex = history.length - 1;
    }

    url = newUrl;
    lastVisitedAt = DateTime.now();
  }

  /// Go back in this tab's history. Returns the URL to navigate to, or null.
  String? goBack() {
    if (historyIndex <= 0) return null;
    historyIndex--;
    url = history[historyIndex];
    lastVisitedAt = DateTime.now();
    return url;
  }

  /// Go forward in this tab's history. Returns the URL to navigate to, or null.
  String? goForward() {
    if (historyIndex >= history.length - 1) return null;
    historyIndex++;
    url = history[historyIndex];
    lastVisitedAt = DateTime.now();
    return url;
  }

  bool get canGoBackInHistory => historyIndex > 0;
  bool get canGoForwardInHistory => historyIndex < history.length - 1;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'faviconUrl': faviconUrl,
      'lastVisitedAt': lastVisitedAt.millisecondsSinceEpoch,
      'history': history,
      'historyIndex': historyIndex,
    };
  }

  factory BrowserTab.fromMap(Map<String, dynamic> map) {
    final historyRaw = map['history'];
    final List<String> history = historyRaw is List
        ? historyRaw.map((e) => e.toString()).toList()
        : [map['url'] as String];

    return BrowserTab(
      id: map['id'] as String?,
      url: map['url'] as String,
      title: map['title'] as String? ?? 'New Tab',
      faviconUrl: map['faviconUrl'] as String?,
      lastVisitedAt: map['lastVisitedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(map['lastVisitedAt'] as int)
          : null,
      history: history,
      historyIndex: map['historyIndex'] as int? ?? (history.length - 1).clamp(0, history.length - 1),
    );
  }
}

/// A single entry in the global browsing history.
class BrowsingHistoryEntry {
  final String url;
  final String title;
  final DateTime visitedAt;
  final String? faviconUrl;

  const BrowsingHistoryEntry({
    required this.url,
    required this.title,
    required this.visitedAt,
    this.faviconUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'title': title,
      'visitedAt': visitedAt.millisecondsSinceEpoch,
      'faviconUrl': faviconUrl,
    };
  }

  factory BrowsingHistoryEntry.fromMap(Map<String, dynamic> map) {
    return BrowsingHistoryEntry(
      url: map['url'] as String,
      title: map['title'] as String? ?? '',
      visitedAt: DateTime.fromMillisecondsSinceEpoch(
        map['visitedAt'] as int? ?? 0,
      ),
      faviconUrl: map['faviconUrl'] as String?,
    );
  }
}
