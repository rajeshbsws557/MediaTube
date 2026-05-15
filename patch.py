
import sys

with open('lib/screens/browser_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

decl_old = '''  late final AnimationController _streamPulseController;

  bool _shouldEnableRequestInterception(BrowserProvider provider) {'''

decl_new = '''  late final AnimationController _streamPulseController;
  StreamSubscription<NativePlaybackControlEvent>? _nativeControlSubscription;

  bool _shouldEnableRequestInterception(BrowserProvider provider) {'''

init_old = '''    unawaited(_nativePlaybackBridge.ensureListening());
    unawaited(_ensureAndroidSdkInt());'''

init_new = '''    unawaited(_nativePlaybackBridge.ensureListening());
    _nativeControlSubscription = _nativePlaybackBridge.controlEvents.listen(
      (event) {
        unawaited(_handleNativePlaybackControlEvent(event));
      },
    );
    unawaited(_ensureAndroidSdkInt());'''

disp_old = '''  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detachFrameTimingProbe();'''

disp_new = '''  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nativeControlSubscription?.cancel();
    _detachFrameTimingProbe();'''

handle_new = '''  Future<void> _handleNativePlaybackControlEvent(
    NativePlaybackControlEvent event,
  ) async {
    final controller = _webViewController;
    if (controller == null) {
      return;
    }

    switch (event.action) {
      case NativePlaybackControlAction.play:
        unawaited(controller.evaluateJavascript(source: \\'\\'\\'
          (() => {
            document.querySelectorAll('video').forEach((v) => {
              v.dataset.mtUserIntent = 'play';
              v.dataset.mtBackgroundPlay = 'true';
              v.play();
            });
          })();
        \\'\\'\\'));
        break;
      case NativePlaybackControlAction.pause:
        unawaited(controller.evaluateJavascript(source: \\'\\'\\'
          (() => {
            document.querySelectorAll('video').forEach((v) => {
              v.dataset.mtUserIntent = 'pause';
              delete v.dataset.mtBackgroundPlay;
              v.pause();
            });
          })();
        \\'\\'\\'));
        break;
      case NativePlaybackControlAction.toggle:
        unawaited(controller.evaluateJavascript(source: \\'\\'\\'
          (() => {
            document.querySelectorAll('video').forEach((v) => {
              if (v.paused) {
                v.dataset.mtUserIntent = 'play';
                v.dataset.mtBackgroundPlay = 'true';
                v.play();
              } else {
                v.dataset.mtUserIntent = 'pause';
                delete v.dataset.mtBackgroundPlay;
                v.pause();
              }
            });
          })();
        \\'\\'\\'));
        break;
      case NativePlaybackControlAction.stop:
        unawaited(controller.evaluateJavascript(source: \\'\\'\\'
          (() => {
            document.querySelectorAll('video').forEach((v) => {
              v.dataset.mtUserIntent = 'pause';
              delete v.dataset.mtBackgroundPlay;
              v.pause();
            });
          })();
        \\'\\'\\'));
        _stopBackgroundPlaybackAutomationLoop();
        unawaited(_stopPlaybackForegroundProtection());
        break;
      case NativePlaybackControlAction.seek:
        final pos = event.position;
        if (pos != null) {
          unawaited(controller.evaluateJavascript(source: \\'\\'\\'
            (() => {
              document.querySelectorAll('video').forEach((v) => {
                v.currentTime = ;
              });
            })();
          \\'\\'\\'));
        }
        break;
    }
  }

'''

content = content.replace(decl_old, decl_new)
content = content.replace(init_old, init_new)
content = content.replace(disp_old, disp_new)

disp_index = content.find('  @override\\n  void dispose() {')
if disp_index == -1:
    disp_index = content.find('  void dispose() {')

if disp_index != -1:
    content = content[:disp_index] + handle_new + content[disp_index:]

with open('lib/screens/browser_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)

