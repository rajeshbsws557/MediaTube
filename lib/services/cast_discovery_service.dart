import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum CastDeviceType { chromecast, dlna, roku, unknown }

class CastDevice {
  final String id;
  final String name;
  final CastDeviceType type;
  final bool isConnected;
  final String? location;

  const CastDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isConnected,
    this.location,
  });

  factory CastDevice.fromMap(Map<Object?, Object?> map) {
    final rawType = (map['type']?.toString() ?? '').toLowerCase();
    final type = switch (rawType) {
      'chromecast' => CastDeviceType.chromecast,
      'dlna' => CastDeviceType.dlna,
      'roku' => CastDeviceType.roku,
      _ => CastDeviceType.unknown,
    };

    return CastDevice(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Display',
      type: type,
      isConnected: map['isConnected'] == true,
      location: map['location']?.toString(),
    );
  }
}

class CastDiscoveryService extends ChangeNotifier {
  CastDiscoveryService._internal();

  static final CastDiscoveryService _instance =
      CastDiscoveryService._internal();

  factory CastDiscoveryService() => _instance;

  static const MethodChannel _methodChannel =
      MethodChannel('com.rajesh.mediatube/cast');
  static const EventChannel _eventChannel =
      EventChannel('com.rajesh.mediatube/cast_events');

  final List<CastDevice> _devices = <CastDevice>[];
  StreamSubscription<dynamic>? _eventsSub;

  bool _listening = false;
  bool _isDiscovering = false;
  String? _connectedDeviceId;
  String? _lastError;

  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get hasCompatibleDevices => _devices.isNotEmpty;
  bool get isDiscovering => _isDiscovering;
  String? get connectedDeviceId => _connectedDeviceId;
  String? get lastError => _lastError;

  CastDevice? get connectedDevice {
    final connected = _devices.where((d) => d.id == _connectedDeviceId);
    return connected.isEmpty ? null : connected.first;
  }

  Future<void> ensureInitialized() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (!_listening) {
      _eventsSub = _eventChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (_) {
          _lastError = 'Cast event channel failed';
          notifyListeners();
        },
      );
      _listening = true;
    }

    await refreshDevices();
  }

  Future<void> startDiscovery() async {
    if (!Platform.isAndroid) {
      return;
    }

    await ensureInitialized();
    await _methodChannel.invokeMethod<void>('startDiscovery');
    _isDiscovering = true;
    await refreshDevices();
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _methodChannel.invokeMethod<void>('stopDiscovery');
    _isDiscovering = false;
    notifyListeners();
  }

  Future<void> refreshDevices() async {
    if (!Platform.isAndroid) {
      return;
    }

    final result = await _methodChannel.invokeMethod<List<dynamic>>('getDevices');
    if (result == null) {
      return;
    }

    _devices
      ..clear()
      ..addAll(
        result
            .whereType<Map>()
            .map((raw) => CastDevice.fromMap(raw.cast<Object?, Object?>())),
      );

    final connected = await _methodChannel.invokeMethod<String?>(
      'getConnectedDeviceId',
    );
    _connectedDeviceId = connected;
    notifyListeners();
  }

  Future<bool> connectToDevice(String deviceId) async {
    if (!Platform.isAndroid || deviceId.isEmpty) {
      return false;
    }

    final success = await _methodChannel.invokeMethod<bool>(
      'connectToDevice',
      {'deviceId': deviceId},
    );

    if (success == true) {
      _connectedDeviceId = deviceId;
      await refreshDevices();
      notifyListeners();
      return true;
    }

    return false;
  }

  Future<void> disconnect() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _methodChannel.invokeMethod<void>('disconnect');
    _connectedDeviceId = null;
    await refreshDevices();
    notifyListeners();
  }

  Future<bool> castMedia({
    required String mediaUrl,
    required String title,
    String subtitle = '',
    String mimeType = 'video/mp4',
    String? imageUrl,
    String? preferredDeviceId,
    Duration position = Duration.zero,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final success = await _methodChannel.invokeMethod<bool>('castMedia', {
      'deviceId': preferredDeviceId,
      'mediaUrl': mediaUrl,
      'title': title,
      'subtitle': subtitle,
      'mimeType': mimeType,
      'imageUrl': imageUrl,
      'positionMs': position.inMilliseconds,
    });

    return success == true;
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) {
      return;
    }

    final payload = event.cast<Object?, Object?>();
    final type = payload['event']?.toString();

    if (type == 'devicesUpdated') {
      final rawDevices = payload['devices'];
      if (rawDevices is List) {
        _devices
          ..clear()
          ..addAll(
            rawDevices
                .whereType<Map>()
                .map((raw) => CastDevice.fromMap(raw.cast<Object?, Object?>())),
          );
      }

      final connected = _devices.where((d) => d.isConnected).toList();
      _connectedDeviceId = connected.isEmpty ? _connectedDeviceId : connected.first.id;
      notifyListeners();
      return;
    }

    if (type == 'connectionChanged') {
      _connectedDeviceId = payload['connectedDeviceId']?.toString();
      notifyListeners();
      return;
    }

    if (type == 'error') {
      _lastError = payload['message']?.toString();
      notifyListeners();
    }
  }

  Future<void> disposePlatformBindings() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    _listening = false;
    _isDiscovering = false;
  }
}
