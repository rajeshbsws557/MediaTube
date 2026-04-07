import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/services.dart';

class NearbyRadarScreen extends StatefulWidget {
  const NearbyRadarScreen({super.key});

  @override
  State<NearbyRadarScreen> createState() => _NearbyRadarScreenState();
}

class _NearbyRadarScreenState extends State<NearbyRadarScreen>
    with SingleTickerProviderStateMixin {
  final NearbyP2PService _nearbyService = NearbyP2PService();
  late final AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();

    _nearbyService.addListener(_onNearbyUpdate);
    unawaited(_initializeRadar());
  }

  @override
  void dispose() {
    _nearbyService.removeListener(_onNearbyUpdate);
    unawaited(_nearbyService.stopRadar());
    _radarController.dispose();
    super.dispose();
  }

  void _onNearbyUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _initializeRadar() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _requestNearbyPermissions();
    await _nearbyService.ensureInitialized();
    await _nearbyService.startRadar();
  }

  Future<void> _requestNearbyPermissions() async {
    final permissions = <Permission>[
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ];

    for (final permission in permissions) {
      try {
        await permission.request();
      } catch (_) {
        // Some permissions do not exist on old Android APIs.
      }
    }
  }

  Future<void> _connectToPeer(NearbyPeer peer) async {
    final ok = await _nearbyService.requestConnection(peer.endpointId);
    if (!mounted) {
      return;
    }

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to request connection to ${peer.endpointName}')),
      );
    }
  }

  Future<void> _acceptRequest(NearbyConnectionRequest request) async {
    await _nearbyService.acceptConnection(request.endpointId);
    await _nearbyService.refreshPeers();
  }

  Future<void> _rejectRequest(NearbyConnectionRequest request) async {
    await _nearbyService.rejectConnection(request.endpointId);
  }

  Future<void> _disconnectPeer(NearbyPeer peer) async {
    await _nearbyService.disconnectPeer(peer.endpointId);
    await _nearbyService.refreshPeers();
  }

  Future<void> _showFileSendSheet(NearbyPeer peer) async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: Consumer<DownloadProvider>(
              builder: (context, provider, _) {
                final completed = provider.completedDownloads;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                      child: Text(
                        'Send to ${peer.endpointName}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const Divider(height: 1),
                    if (completed.isEmpty)
                      const Expanded(
                        child: Center(
                          child: Text('No completed downloads available'),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          itemCount: completed.length,
                          itemBuilder: (context, index) {
                            final task = completed[index];
                            return ListTile(
                              leading: Icon(
                                task.isAudioOnly
                                    ? Icons.audio_file
                                    : Icons.video_file,
                              ),
                              title: Text(
                                task.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(task.totalSizeFormatted),
                              trailing: const Icon(Icons.send),
                              onTap: () {
                                unawaited(_sendTaskToPeer(peer, task));
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _sendTaskToPeer(NearbyPeer peer, DownloadTask task) async {
    final file = File(task.savePath);
    if (!await file.exists()) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File no longer exists on device')),
      );
      return;
    }

    final ok = await _nearbyService.sendFile(
      endpointId: peer.endpointId,
      filePath: task.savePath,
    );

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Sending ${task.fileName} to ${peer.endpointName}'
              : 'Could not start transfer to ${peer.endpointName}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Radar Share'),
        actions: [
          IconButton(
            tooltip: 'Restart radar',
            onPressed: () async {
              await _nearbyService.stopRadar();
              await _nearbyService.startRadar();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 16),
            SizedBox(
              width: 220,
              height: 220,
              child: AnimatedBuilder(
                animation: _radarController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _RadarPainter(_radarController.value),
                    child: const Center(
                      child: CircleAvatar(
                        radius: 28,
                        child: Icon(Icons.radar, size: 30),
                      ),
                    ),
                  );
                },
              ),
            ),
            Text(
              _nearbyService.isRadarRunning
                  ? 'Scanning for nearby MediaTube users'
                  : 'Radar is paused',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('${_nearbyService.peers.length} users detected nearby'),
            if (_nearbyService.lastError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _nearbyService.lastError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (_nearbyService.requests.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: _nearbyService.requests.map((request) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${request.endpointName} wants to connect',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text('Security code: ${request.authToken}'),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              unawaited(_rejectRequest(request));
                            },
                            child: const Text('Reject'),
                          ),
                          FilledButton(
                            onPressed: () {
                              unawaited(_acceptRequest(request));
                            },
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: _nearbyService.peers.length,
                itemBuilder: (context, index) {
                  final peer = _nearbyService.peers[index];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        peer.isConnected
                            ? Icons.bluetooth_connected
                            : Icons.person_search,
                    ),
                    title: Text(peer.endpointName),
                    subtitle: Text(
                      peer.isConnected
                          ? 'Connected'
                          : (peer.isPending ? 'Connection pending' : 'Available'),
                    ),
                    trailing: peer.isConnected
                        ? Wrap(
                            spacing: 6,
                            children: [
                              IconButton(
                                tooltip: 'Send file',
                                onPressed: () {
                                  unawaited(_showFileSendSheet(peer));
                                },
                                icon: const Icon(Icons.send),
                              ),
                              IconButton(
                                tooltip: 'Disconnect',
                                onPressed: () {
                                  unawaited(_disconnectPeer(peer));
                                },
                                icon: const Icon(Icons.link_off),
                              ),
                            ],
                          )
                        : FilledButton.tonal(
                            onPressed: peer.isPending
                                ? null
                                : () {
                                    unawaited(_connectToPeer(peer));
                                  },
                            child: Text(peer.isPending ? 'Pending' : 'Connect'),
                          ),
                  ),
                );
              },
            ),
          ),
          if (_nearbyService.transfers.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _nearbyService.transfers.take(2).map((transfer) {
                  final fileLabel = transfer.fileName ?? 'Transfer ${transfer.payloadId}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$fileLabel • ${_statusLabel(transfer.status)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: transfer.isCompleted ? 1 : transfer.progress,
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    ),
    );
  }

  String _statusLabel(int status) {
    return switch (status) {
      1 => 'Complete',
      2 => 'Failed',
      3 => 'In progress',
      4 => 'Canceled',
      _ => 'Starting',
    };
  }
}

class _RadarPainter extends CustomPainter {
  final double t;

  _RadarPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width * 0.46;

    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = const Color(0xFF2B7FFF).withAlpha(140);

    for (int i = 0; i < 3; i++) {
      final phase = (t + (i * 0.33)) % 1.0;
      final radius = 34 + (maxRadius - 34) * phase;
      final opacity = (1 - phase) * 0.65;
      canvas.drawCircle(
        center,
        radius,
        basePaint..color = const Color(0xFF2B7FFF).withValues(alpha: opacity),
      );
    }

    final dotPaint = Paint()
      ..color = const Color(0xFF42E6A4)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < 8; i++) {
      final angle = (i / 8) * 6.28318 + (t * 0.9);
      final orbit = 75 + (i % 2) * 20;
      final x = center.dx + orbit * (0.95 * math.cos(angle));
      final y = center.dy + orbit * (0.95 * math.sin(angle));
      canvas.drawCircle(Offset(x, y), 2.4, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) {
    return oldDelegate.t != t;
  }
}
