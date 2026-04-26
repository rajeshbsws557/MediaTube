import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  var yt = YoutubeExplode();
  try {
    var videoId = 'dQw4w9WgXcQ';
    print(videoId);
    var video = await yt.videos.get(videoId);
    print(video.title);
  } catch (e, stack) {
    print(e);
    print(stack);
  } finally {
    yt.close();
  }
}
