import 'dart:math';

/// Simple unique ID generator without external dependency.
String _generateBookmarkId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(99999);
  return 'bm_${now}_$rand';
}

class Bookmark {
  final String id;
  String url;
  String title;
  String? faviconUrl;
  final DateTime createdAt;

  Bookmark({
    String? id,
    required this.url,
    required this.title,
    this.faviconUrl,
    DateTime? createdAt,
  })  : id = id ?? _generateBookmarkId(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'faviconUrl': faviconUrl,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Bookmark.fromMap(Map<String, dynamic> map) {
    return Bookmark(
      id: map['id'] as String?,
      url: map['url'] as String? ?? '',
      title: map['title'] as String? ?? '',
      faviconUrl: map['faviconUrl'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
