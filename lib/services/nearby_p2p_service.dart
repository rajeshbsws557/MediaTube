import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NearbyPeer {
  final String endpointId;
  final String endpointName;
  final bool isConnected;
  final bool isPending;

  const NearbyPeer({
    required this.endpointId,
    required this.endpointName,
    required this.isConnected,
    required this.isPending,
  });

  NearbyPeer copyWith({
    String? endpointId,
    String? endpointName,
    bool? isConnected,
    bool? isPending,
  }) {
    return NearbyPeer(
      endpointId: endpointId ?? this.endpointId,
      endpointName: endpointName ?? this.endpointName,
      isConnected: isConnected ?? this.isConnected,
      isPending: isPending ?? this.isPending,
    );
  }

  factory NearbyPeer.fromMap(Map<Object?, Object?> map) {
    return NearbyPeer(
      endpointId: map['endpointId']?.toString() ?? '',
      endpointName: map['endpointName']?.toString() ?? 'Nearby device',
      isConnected: map['isConnected'] == true,
      isPending: map['isPending'] == true,
    );
  }
}

class NearbyConnectionRequest {
  final String endpointId;
  final String endpointName;
  final String authToken;
  final bool isIncoming;

  const NearbyConnectionRequest({
    required this.endpointId,
    required this.endpointName,
    required this.authToken,
    required this.isIncoming,
  });
}

class NearbyTransferProgress {
  final int payloadId;
  final String endpointId;
  final String? fileName;
  final int status;
  final int bytesTransferred;
  final int totalBytes;

  const NearbyTransferProgress({
    required this.payloadId,
    required this.endpointId,
    required this.fileName,
    required this.status,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  double get progress {
    if (totalBytes <= 0) {
      return 0;
    }
    return bytesTransferred / totalBytes;
  }

  bool get isCompleted => status == 1;
  bool get isFailed => status == 2 || status == 4;
}

class NearbyP2PService extends ChangeNotifier {
  NearbyP2PService._internal();

  static final NearbyP2PService _instance = NearbyP2PService._internal();

  factory NearbyP2PService() => _instance;

  static const MethodChannel _methodChannel =
      MethodChannel('com.rajesh.mediatube/nearby');
  static const EventChannel _eventChannel =
      EventChannel('com.rajesh.mediatube/nearby_events');

  final Map<String, NearbyPeer> _peerMap = <String, NearbyPeer>{};
  final Map<String, NearbyConnectionRequest> _requests =
      <String, NearbyConnectionRequest>{};
  final Map<int, NearbyTransferProgress> _transfers =
      <int, NearbyTransferProgress>{};
  final List<String> _receivedFiles = <String>[];

  StreamSubscription<dynamic>? _eventsSub;
  bool _isListening = false;
  bool _isRadarRunning = false;
  String? _lastError;

  List<NearbyPeer> get peers {
    final values = _peerMap.values.toList();
    values.sort((a, b) {
      if (a.isConnected != b.isConnected) {
        return a.isConnected ? -1 : 1;
      }
      return a.endpointName.toLowerCase().compareTo(b.endpointName.toLowerCase());
    });
    return values;
  }

  List<NearbyPeer> get connectedPeers =>
      peers.where((peer) => peer.isConnected).toList();

  List<NearbyConnectionRequest> get requests => _requests.values.toList();

  List<NearbyTransferProgress> get transfers {
    final values = _transfers.values.toList();
    values.sort((a, b) => b.payloadId.compareTo(a.payloadId));
    return values;
  }

  List<String> get receivedFiles => List.unmodifiable(_receivedFiles);

  bool get isRadarRunning => _isRadarRunning;
  String? get lastError => _lastError;

  Future<void> ensureInitialized() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (!_isListening) {
      _eventsSub = _eventChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (_) {
          _lastError = 'Nearby event stream error';
          notifyListeners();
        },
      );
      _isListening = true;
    }

    await refreshPeers();
  }

  Future<void> startRadar({String? endpointName}) async {
    if (!Platform.isAndroid) {
      return;
    }

    await ensureInitialized();

    await _methodChannel.invokeMethod<void>('startRadar', {
      if (endpointName != null) 'endpointName': endpointName,
    });
    _isRadarRunning = true;
    notifyListeners();
  }

  Future<void> stopRadar() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _methodChannel.invokeMethod<void>('stopRadar');
    _isRadarRunning = false;
    _peerMap.clear();
    _requests.clear();
    _transfers.clear();
    notifyListeners();
  }

  Future<void> refreshPeers() async {
    if (!Platform.isAndroid) {
      return;
    }

    final raw = await _methodChannel.invokeMethod<List<dynamic>>('getPeers');
    if (raw == null) {
      return;
    }

    _peerMap
      ..clear()
      ..addEntries(
        raw.whereType<Map>().map((map) {
          final peer = NearbyPeer.fromMap(map.cast<Object?, Object?>());
          return MapEntry(peer.endpointId, peer);
        }),
      );
    notifyListeners();
  }

  Future<bool> requestConnection(String endpointId) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final ok = await _methodChannel.invokeMethod<bool>('requestConnection', {
      'endpointId': endpointId,
    });

    return ok == true;
  }

  Future<bool> acceptConnection(String endpointId) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final ok = await _methodChannel.invokeMethod<bool>('acceptConnection', {
      'endpointId': endpointId,
    });

    return ok == true;
  }

  Future<bool> rejectConnection(String endpointId) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final ok = await _methodChannel.invokeMethod<bool>('rejectConnection', {
      'endpointId': endpointId,
    });

    if (ok == true) {
      _requests.remove(endpointId);
      notifyListeners();
    }

    return ok == true;
  }

  Future<bool> disconnectPeer(String endpointId) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final ok = await _methodChannel.invokeMethod<bool>('disconnectPeer', {
      'endpointId': endpointId,
    });

    if (ok == true) {
      final peer = _peerMap[endpointId];
      if (peer != null) {
        _peerMap[endpointId] = peer.copyWith(isConnected: false, isPending: false);
      }
      notifyListeners();
    }

    return ok == true;
  }

  Future<bool> sendFile({
    required String endpointId,
    required String filePath,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final ok = await _methodChannel.invokeMethod<bool>('sendFile', {
      'endpointId': endpointId,
      'filePath': filePath,
    });

    return ok == true;
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) {
      return;
    }

    final payload = event.cast<Object?, Object?>();
    final type = payload['event']?.toString() ?? '';

    switch (type) {
      case 'peerFound':
        final endpointId = payload['endpointId']?.toString() ?? '';
        if (endpointId.isEmpty) break;
        final current = _peerMap[endpointId];
        _peerMap[endpointId] = (current ??
                NearbyPeer(
                  endpointId: endpointId,
                  endpointName: payload['endpointName']?.toString() ??
                      'Nearby device',
                  isConnected: false,
                  isPending: false,
                ))
            .copyWith(
              endpointName:
                  payload['endpointName']?.toString() ?? current?.endpointName,
            );
        notifyListeners();
        break;

      case 'peerLost':
        final endpointId = payload['endpointId']?.toString() ?? '';
        if (endpointId.isEmpty) break;
        final current = _peerMap[endpointId];
        if (current != null && !current.isConnected) {
          _peerMap.remove(endpointId);
          notifyListeners();
        }
        break;

      case 'connectionInitiated':
        final endpointId = payload['endpointId']?.toString() ?? '';
        if (endpointId.isEmpty) break;

        final endpointName =
            payload['endpointName']?.toString() ?? 'Nearby device';
        _peerMap[endpointId] = (_peerMap[endpointId] ??
                NearbyPeer(
                  endpointId: endpointId,
                  endpointName: endpointName,
                  isConnected: false,
                  isPending: true,
                ))
            .copyWith(isPending: true, endpointName: endpointName);

        _requests[endpointId] = NearbyConnectionRequest(
          endpointId: endpointId,
          endpointName: endpointName,
          authToken: payload['authenticationToken']?.toString() ?? '',
          isIncoming: payload['isIncomingConnection'] == true,
        );
        notifyListeners();
        break;

      case 'connectionResult':
        final endpointId = payload['endpointId']?.toString() ?? '';
        if (endpointId.isEmpty) break;
        final connected = payload['connected'] == true;
        _requests.remove(endpointId);
        final current = _peerMap[endpointId];
        if (current != null) {
          _peerMap[endpointId] = current.copyWith(
            isConnected: connected,
            isPending: false,
          );
        }
        notifyListeners();
        break;

      case 'disconnected':
        final endpointId = payload['endpointId']?.toString() ?? '';
        if (endpointId.isEmpty) break;
        final current = _peerMap[endpointId];
        if (current != null) {
          _peerMap[endpointId] =
              current.copyWith(isConnected: false, isPending: false);
          notifyListeners();
        }
        break;

      case 'transferUpdate':
        final payloadId = (payload['payloadId'] as num?)?.toInt();
        if (payloadId == null) break;

        _transfers[payloadId] = NearbyTransferProgress(
          payloadId: payloadId,
          endpointId: payload['endpointId']?.toString() ?? '',
          fileName: payload['fileName']?.toString(),
          status: (payload['status'] as num?)?.toInt() ?? 0,
          bytesTransferred:
              (payload['bytesTransferred'] as num?)?.toInt() ?? 0,
          totalBytes: (payload['totalBytes'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
        break;

      case 'fileReceived':
        final path = payload['filePath']?.toString();
        if (path != null && path.isNotEmpty) {
          _receivedFiles.insert(0, path);
          notifyListeners();
        }
        break;

      case 'error':
        _lastError = payload['message']?.toString();
        notifyListeners();
        break;
    }
  }

  Future<void> disposePlatformBindings() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isListening = false;
  }
}
