import 'package:flutter_inappwebview/flutter_inappwebview.dart'; void main() { var s = InAppWebViewSettings(useShouldInterceptRequest: true); print(s.allowBackgroundAudioPlaying); }
