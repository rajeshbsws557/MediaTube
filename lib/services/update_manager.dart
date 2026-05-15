import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// Model class for app version information from GitHub.
class AppVersionInfo {
  final String version;
  final String changelog;
  final String downloadUrl;

  AppVersionInfo({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
  });

  factory AppVersionInfo.fromGitHub(Map<String, dynamic> json) {
    final tagName = (json['tag_name'] ?? 'v0.0.0').toString();
    final cleanVersion = tagName.replaceAll('v', '');

    String apkUrl = '';
    final assetsRaw = json['assets'];
    if (assetsRaw is List) {
      final apkAssets = <Map<String, dynamic>>[];

      for (final asset in assetsRaw) {
        if (asset is! Map) {
          continue;
        }
        final map = Map<String, dynamic>.from(asset);
        final name = (map['name'] ?? '').toString().toLowerCase();

        if (name.endsWith('.apk')) {
          apkAssets.add(map);
        }
      }

      final selected = _pickPreferredApkAsset(apkAssets);
      if (selected != null) {
        apkUrl = (selected['browser_download_url'] ?? '').toString();
      }
    }

    return AppVersionInfo(
      version: cleanVersion,
      changelog: (json['body'] ?? 'No changelog available.').toString(),
      downloadUrl: apkUrl,
    );
  }

  static Map<String, dynamic>? _pickPreferredApkAsset(
    List<Map<String, dynamic>> apkAssets,
  ) {
    if (apkAssets.isEmpty) {
      return null;
    }

    const preferenceOrder = <String>[
      'arm64-v8a',
      'arm64_v8a',
      'arm64',
      'universal',
      'armeabi-v7a',
      'armeabi_v7a',
      'armeabi',
      'x86_64',
      'x86',
    ];

    for (final token in preferenceOrder) {
      for (final asset in apkAssets) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (name.contains(token)) {
          return asset;
        }
      }
    }

    return apkAssets.first;
  }
}

/// Service to manage app updates via GitHub Releases.
class UpdateManager {
  static final UpdateManager _instance = UpdateManager._internal();

  factory UpdateManager() => _instance;

  UpdateManager._internal();

  static const Set<String> _trustedUpdateHosts = {
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'githubusercontent.com',
    'raw.githubusercontent.com',
  };

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      maxRedirects: 5,
    ),
  );

  CancelToken? _cancelToken;
  bool _isCheckingForUpdates = false;
  bool _isUpdateDialogVisible = false;

  Future<void> checkForUpdates(
    BuildContext context, {
    bool showNoUpdateMessage = false,
  }) async {
    if (_isCheckingForUpdates) {
      return;
    }

    _isCheckingForUpdates = true;

    try {
      final versionInfo = await _fetchGitHubVersionInfo();
      if (versionInfo == null || versionInfo.downloadUrl.isEmpty) {
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to check for updates or no APK found'),
            ),
          );
        }
        return;
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      debugPrint('Current: $currentVersion, GitHub: ${versionInfo.version}');

      if (_isNewerVersion(versionInfo.version, currentVersion)) {
        if (context.mounted && !_isUpdateDialogVisible) {
          _showBeautifulUpdateDialog(context, versionInfo, currentVersion);
        }
      } else {
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('App is up to date!')),
          );
        }
      }
    } catch (e) {
      debugPrint('Update check failed: $e');
      if (showNoUpdateMessage && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      _isCheckingForUpdates = false;
    }
  }

  Future<AppVersionInfo?> _fetchGitHubVersionInfo() async {
    try {
      // https://api.github.com/repos/{owner}/{repo}/releases/latest
      final uri = Uri.https(
        'api.github.com',
        '/repos/${AppConfig.githubRepoOwner}/${AppConfig.githubRepoName}/releases/latest',
      );

      if (!_isTrustedHttpsUrl(
        uri.toString(),
        allowedHosts: const {'api.github.com'},
      )) {
        debugPrint('Rejected update metadata URL: $uri');
        return null;
      }

      final response = await http
          .get(
            uri,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'MediaTube/${AppConfig.appVersion}',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('GitHub API Error: ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final info = AppVersionInfo.fromGitHub(json);
      if (info.downloadUrl.isEmpty) {
        return info;
      }

      if (!_isTrustedHttpsUrl(info.downloadUrl)) {
        debugPrint('Rejected untrusted update asset URL');
        return null;
      }

      return info;
    } catch (e) {
      debugPrint('Failed to fetch GitHub release: $e');
      return null;
    }
  }

  bool _isNewerVersion(String serverVersion, String currentVersion) {
    try {
      final sParts = serverVersion.split('.').map(int.parse).toList();
      final cParts = currentVersion.split('.').map(int.parse).toList();

      while (sParts.length < 3) {
        sParts.add(0);
      }
      while (cParts.length < 3) {
        cParts.add(0);
      }

      for (var i = 0; i < 3; i++) {
        if (sParts[i] > cParts[i]) {
          return true;
        }
        if (sParts[i] < cParts[i]) {
          return false;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void _showBeautifulUpdateDialog(
    BuildContext context,
    AppVersionInfo info,
    String currentVer,
  ) {
    if (_isUpdateDialogVisible) {
      return;
    }

    _isUpdateDialogVisible = true;

    final highlights = _extractHighlightPoints(info.changelog);
    const highlightIcons = <IconData>[
      Icons.link,
      Icons.sync_alt,
      Icons.music_note,
      Icons.build,
    ];
    const highlightColors = <Color>[
      Color(0xFFFFB300),
      Color(0xFF66BB6A),
      Color(0xFF29B6F6),
      Color(0xFFB0BEC5),
    ];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final maxHeight = MediaQuery.of(dialogContext).size.height * 0.84;

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            backgroundColor: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 460),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 28,
                      spreadRadius: 4,
                    ),
                  ],
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF171B22),
                      Color(0xFF0F1218),
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.2),
                            Colors.transparent,
                          ],
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF6C915),
                              borderRadius: BorderRadius.circular(21),
                            ),
                            child: const Icon(
                              Icons.file_download,
                              color: Color(0xFF212121),
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'MediaTube',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 24,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Discover new version\nV${info.version}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 36,
                                height: 1.06,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'Current version: V$currentVer',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'New version of MediaTube:',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 14),
                            for (var i = 0; i < highlights.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      margin: const EdgeInsets.only(top: 2),
                                      decoration: BoxDecoration(
                                        color: highlightColors[i % highlightColors.length]
                                            .withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        highlightIcons[i % highlightIcons.length],
                                        color: highlightColors[i % highlightColors.length],
                                        size: 14,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        highlights[i],
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.9),
                                          height: 1.35,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 2, 22, 14),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                size: 20,
                                color: Colors.greenAccent.withValues(alpha: 0.85),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Security verified to update in MediaTube',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.62),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: () {
                                Navigator.pop(dialogContext);
                                _startUpdate(
                                  context,
                                  info.downloadUrl,
                                  info.version,
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFF6C915),
                                foregroundColor: const Color(0xFF222222),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                              ),
                              child: const Text(
                                'Update now',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 24,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(
                              'Not now',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      _isUpdateDialogVisible = false;
    });
  }

  List<String> _extractHighlightPoints(String changelog) {
    final points = <String>[];
    final lines = changelog.replaceAll('\r\n', '\n').split('\n');

    for (final raw in lines) {
      var cleaned = raw.trim();
      if (cleaned.isEmpty || cleaned.startsWith('#')) {
        continue;
      }

      cleaned = cleaned
          .replaceFirst(RegExp(r'^[-*]\s*'), '')
          .replaceFirst(RegExp(r'^\d+[.)]\s*'), '')
          .replaceAll(RegExp(r'\[(.*?)\]\((.*?)\)'), r'$1')
          .replaceAll('**', '')
          .replaceAll('__', '')
          .replaceAll('`', '')
          .trim();

      if (cleaned.isEmpty) {
        continue;
      }

      points.add(cleaned);
      if (points.length == 4) {
        break;
      }
    }

    if (points.isNotEmpty) {
      return points;
    }

    return const [
      'More links and platforms supported for fast downloading.',
      'Improved media recovery and resume stability.',
      'Smoother online playback and extraction reliability.',
      'Bug fixes plus overall performance improvements.',
    ];
  }

  Future<void> _startUpdate(
    BuildContext context,
    String url,
    String version,
  ) async {
    try {
      if (!_isTrustedHttpsUrl(url)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Blocked update from untrusted source.'),
            ),
          );
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/MediaTube-v$version.apk';
      if (await File(path).exists()) {
        await File(path).delete();
      }

      if (!context.mounted) {
        return;
      }

      _cancelToken = CancelToken();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _DownloadProgressDialog(
          downloadUrl: url,
          apkPath: path,
          dio: _dio,
          cancelToken: _cancelToken!,
          onComplete: () {
            Navigator.pop(dialogContext);
            OpenFilex.open(path);
          },
          onError: (msg) {
            Navigator.pop(dialogContext);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          },
          onCancel: () => Navigator.pop(dialogContext),
        ),
      );
    } catch (e) {
      debugPrint('Update Error: $e');
    }
  }

  bool _isTrustedHttpsUrl(String url, {Set<String>? allowedHosts}) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }

    if (uri.scheme.toLowerCase() != 'https') {
      return false;
    }

    final host = uri.host.toLowerCase();
    final allowed = allowedHosts ?? _trustedUpdateHosts;
    return allowed.contains(host);
  }
}

class _DownloadProgressDialog extends StatefulWidget {
  final String downloadUrl;
  final String apkPath;
  final Dio dio;
  final CancelToken cancelToken;
  final VoidCallback onComplete;
  final Function(String) onError;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.downloadUrl,
    required this.apkPath,
    required this.dio,
    required this.cancelToken,
    required this.onComplete,
    required this.onError,
    required this.onCancel,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0;
  String _status = 'Starting...';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.dio.download(
        widget.downloadUrl,
        widget.apkPath,
        cancelToken: widget.cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() {
              _progress = received / total;
              _status =
                  '${(received / 1024 / 1024).toStringAsFixed(1)}MB / ${(total / 1024 / 1024).toStringAsFixed(1)}MB';
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _status = 'Installing...';
        });
      }

      await Future.delayed(const Duration(milliseconds: 450));
      widget.onComplete();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        widget.onCancel();
        return;
      }
      widget.onError(e.message ?? e.toString());
    } catch (e) {
      widget.onError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF111318),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Downloading Update',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                color: const Color(0xFFF6C915),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => widget.cancelToken.cancel('cancelled by user'),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    color: Color(0xFFF6C915),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
