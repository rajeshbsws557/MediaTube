import 'package:uuid/uuid.dart';

class BrowserTab {
  final String id;
  String url;
  String title;

  BrowserTab({String? id, required this.url, this.title = 'New Tab'})
    : id = id ?? const Uuid().v4();

  BrowserTab copyWith({String? id, String? url, String? title}) {
    return BrowserTab(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
    );
  }
}
