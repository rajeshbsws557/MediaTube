import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

class LocalStreamServerService {
  LocalStreamServerService._internal();

  static final LocalStreamServerService _instance =
      LocalStreamServerService._internal();

  factory LocalStreamServerService() => _instance;

  HttpServer? _server;
  InternetAddress? _networkAddress;

  final Map<String, String> _tokenToPath = <String, String>{};
  final Map<String, String> _pathToToken = <String, String>{};

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) {
      return;
    }

    _networkAddress = await _resolveLanAddress();
    final bindAddress = InternetAddress.anyIPv4;
    _server = await HttpServer.bind(bindAddress, 0, shared: true);
    unawaited(_server!.forEach(_handleRequest));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _tokenToPath.clear();
    _pathToToken.clear();
    await server?.close(force: true);
  }

  Future<Uri> registerFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    await start();

    final existingToken = _pathToToken[filePath];
    final token = existingToken ?? _generateToken();
    _pathToToken[filePath] = token;
    _tokenToPath[token] = filePath;

    final host = _networkAddress?.address ?? InternetAddress.loopbackIPv4.address;
    final port = _server!.port;
    final name = Uri.encodeComponent(p.basename(filePath));
    return Uri.parse('http://$host:$port/stream/$token/$name');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.pathSegments.length < 2 ||
        request.uri.pathSegments.first != 'stream') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
      await request.response.close();
      return;
    }

    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final token = request.uri.pathSegments[1];
    final filePath = _tokenToPath[token];
    if (filePath == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Unknown media token');
      await request.response.close();
      return;
    }

    final file = File(filePath);
    if (!await file.exists()) {
      request.response
        ..statusCode = HttpStatus.gone
        ..write('Media no longer exists');
      await request.response.close();
      return;
    }

    final fileLength = await file.length();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final contentType = _contentTypeForPath(filePath);
    final response = request.response;

    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');

    if (range != null && range.startsWith('bytes=')) {
      final parsed = _parseRange(range: range, fullLength: fileLength);
      if (parsed == null) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileLength');
        await response.close();
        return;
      }

      final start = parsed.$1;
      final end = parsed.$2;
      final chunkLength = end - start + 1;

      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentLengthHeader, chunkLength)
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$fileLength',
        );

      if (method == 'GET') {
        await response.addStream(file.openRead(start, end + 1));
      }
      await response.close();
      return;
    }

    response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentLengthHeader, fileLength);

    if (method == 'GET') {
      await response.addStream(file.openRead());
    }
    await response.close();
  }

  (int, int)? _parseRange({
    required String range,
    required int fullLength,
  }) {
    final value = range.replaceFirst('bytes=', '').trim();
    if (value.isEmpty || !value.contains('-')) {
      return null;
    }

    final parts = value.split('-');
    if (parts.length != 2) {
      return null;
    }

    final start = int.tryParse(parts[0]);
    final end = parts[1].isEmpty ? null : int.tryParse(parts[1]);

    if (start == null || start < 0 || start >= fullLength) {
      return null;
    }

    final boundedEnd = (end ?? (fullLength - 1)).clamp(start, fullLength - 1);
    return (start, boundedEnd);
  }

  Future<InternetAddress> _resolveLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
      includeLoopback: false,
    );

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          return address;
        }
      }
    }

    return InternetAddress.loopbackIPv4;
  }

  String _generateToken() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = now ^ filePathHashSeed;
    return rand.toRadixString(36);
  }

  String _contentTypeForPath(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return switch (ext) {
      '.mp4' => 'video/mp4',
      '.m4v' => 'video/mp4',
      '.mkv' => 'video/x-matroska',
      '.webm' => 'video/webm',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.aac' => 'audio/aac',
      _ => 'application/octet-stream',
    };
  }
}

const int filePathHashSeed = 0x6d656469;
