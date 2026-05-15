import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:media_tube/models/models.dart';
import 'package:media_tube/services/backend_download_service.dart';
import 'package:media_tube/services/download_service.dart';

class _FakeBackendDownloadService extends BackendDownloadService {
  int directFromUrlCalls = 0;
  int directCalls = 0;
  DetectedMedia? lastDirectMedia;

  @override
  Future<void> downloadDirectFromUrl(
    DownloadTask task,
    String url, {
    required String savePath,
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
    BackendCancelToken? cancelToken,
  }) async {
    directFromUrlCalls++;
    throw Exception('Simulated expired direct URL');
  }

  @override
  Future<void> downloadDirect(
    DownloadTask task,
    DetectedMedia media, {
    required String savePath,
    Function(DownloadTask)? onProgress,
    Function(DownloadTask)? onComplete,
    Function(DownloadTask)? onError,
    BackendCancelToken? cancelToken,
  }) async {
    directCalls++;
    lastDirectMedia = media;
    task.status = DownloadStatus.completed;
    task.progress = 1.0;
    onComplete?.call(task);
  }
}

class _RangeTestServer {
  HttpServer? _server;
  final Uint8List bytes;
  int rangeRequests = 0;

  _RangeTestServer(this.bytes);

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/media.bin');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/media.bin') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.set('accept-ranges', 'bytes');
    request.response.headers.set('content-type', 'application/octet-stream');

    if (request.method == 'HEAD') {
      request.response.headers.set('content-length', bytes.length);
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    int start = 0;
    int end = bytes.length - 1;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      rangeRequests++;
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader);
      if (match != null) {
        start = int.parse(match.group(1)!);
        if (match.group(2) != null && match.group(2)!.isNotEmpty) {
          end = int.parse(match.group(2)!);
        }
      }
      if (start > end || start >= bytes.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      end = min(end, bytes.length - 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${bytes.length}',
      );
      request.response.headers.set('content-length', end - start + 1);
    } else {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('content-length', bytes.length);
    }

    const chunkSize = 64 * 1024;
    int offset = start;
    while (offset <= end) {
      final next = min(offset + chunkSize, end + 1);
      request.response.add(bytes.sublist(offset, next));
      offset = next;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    await request.response.close();
  }
}

void main() {
  group('Download flow integration tests', () {
    test('audio fallback refreshes to canonical watch URL when direct URL fails', () async {
      final fakeBackend = _FakeBackendDownloadService();
      final service = DownloadService(backendService: fakeBackend);

      final media = DetectedMedia(
        url: 'https://rr2---sn.googlevideo.com/videoplayback?id=o-abc123',
        title: 'Sample Audio',
        type: MediaType.audio,
        source: MediaSource.youtube,
        videoId: 'abc123xyz',
        backendQuality: 'audio',
        useBackend: false,
        format: 'm4a',
      );

      final task = DownloadTask(
        id: 'task-audio-fallback',
        url: media.url,
        fileName: 'sample.m4a',
        savePath: 'C:/tmp/sample.m4a',
        isAudioOnly: true,
      );

      final completed = Completer<void>();
      await service.startDownload(
        task,
        media,
        onComplete: (_) => completed.complete(),
        onError: (_) => completed.completeError('Unexpected error callback'),
      );
      await completed.future.timeout(const Duration(seconds: 2));

      expect(fakeBackend.directFromUrlCalls, 1);
      expect(fakeBackend.directCalls, 1);
      expect(
        fakeBackend.lastDirectMedia?.url,
        'https://www.youtube.com/watch?v=abc123xyz',
      );
      expect(fakeBackend.lastDirectMedia?.useBackend, isTrue);

      service.dispose();
      fakeBackend.dispose();
    });

    test('parallel chunk resume completes correctly after pause', () async {
      final random = Random(42);
      final source = Uint8List.fromList(
        List<int>.generate(16 * 1024 * 1024, (_) => random.nextInt(256)),
      );

      final server = _RangeTestServer(source);
      await server.start();

      final backend = BackendDownloadService();
      final tempDir = await Directory.systemTemp.createTemp('mediatube_test_');
      final outputPath = p.join(tempDir.path, 'resume_test.bin');

      final task = DownloadTask(
        id: 'task-resume',
        url: server.url.toString(),
        fileName: 'resume_test.bin',
        savePath: outputPath,
      );

      final firstCancelToken = BackendCancelToken();
      final firstPhaseDone = Completer<void>();

      await backend.downloadDirectFromUrl(
        task,
        server.url.toString(),
        savePath: outputPath,
        cancelToken: firstCancelToken,
        onProgress: (updated) {
          if (!firstCancelToken.isCancelled && updated.totalBytes > 0) {
            if (updated.downloadedBytes > (updated.totalBytes * 0.10).round()) {
              firstCancelToken.cancel('pause for resume test');
            }
          }
          if (updated.status == DownloadStatus.paused && !firstPhaseDone.isCompleted) {
            firstPhaseDone.complete();
          }
        },
      );

      await firstPhaseDone.future.timeout(const Duration(seconds: 20));
      expect(task.status, DownloadStatus.paused);

      final secondCancelToken = BackendCancelToken();
      final secondPhaseDone = Completer<void>();

      await backend.downloadDirectFromUrl(
        task,
        server.url.toString(),
        savePath: outputPath,
        cancelToken: secondCancelToken,
        onComplete: (_) {
          if (!secondPhaseDone.isCompleted) {
            secondPhaseDone.complete();
          }
        },
        onError: (_) {
          if (!secondPhaseDone.isCompleted) {
            secondPhaseDone.completeError('Unexpected error during resume phase');
          }
        },
      );

      await secondPhaseDone.future.timeout(const Duration(seconds: 30));
      expect(task.status, DownloadStatus.completed);

      final downloaded = await File(outputPath).readAsBytes();
      expect(downloaded.length, source.length);
      expect(downloaded, source);
      expect(server.rangeRequests, greaterThan(0));

      await server.close();
      await tempDir.delete(recursive: true);
      backend.dispose();
    });
  });
}
