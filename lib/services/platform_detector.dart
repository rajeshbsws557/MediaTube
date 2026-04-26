import 'media_extractor.dart';

enum SupportedSharePlatform {
  youtube,
  facebook,
  instagram,
  tiktok,
  unsupported,
}

class PlatformDetector {
  PlatformDetector._();

  static final YouTubeExtractor _youTubeExtractor = YouTubeExtractor();
  static final SocialMediaExtractor _socialMediaExtractor =
      SocialMediaExtractor();

  static const Set<String> _youTubeHosts = {
    'youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
  };

  static const Set<String> _facebookHosts = {
    'facebook.com',
    'fb.com',
    'fb.watch',
  };

  static const Set<String> _instagramHosts = {
    'instagram.com',
    'instagr.am',
    'ig.me',
  };

  static const Set<String> _tiktokHosts = {
    'tiktok.com',
    'vm.tiktok.com',
    'vt.tiktok.com',
  };

  static SupportedSharePlatform detect(String cleanedUrl) {
    final uri = Uri.tryParse(cleanedUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return SupportedSharePlatform.unsupported;
    }

    final host = uri.host.toLowerCase();
    if (_hostMatches(host, _youTubeHosts)) {
      return SupportedSharePlatform.youtube;
    }

    if (_hostMatches(host, _facebookHosts)) {
      return SupportedSharePlatform.facebook;
    }

    if (_hostMatches(host, _instagramHosts)) {
      return SupportedSharePlatform.instagram;
    }

    if (_hostMatches(host, _tiktokHosts)) {
      return SupportedSharePlatform.tiktok;
    }

    return SupportedSharePlatform.unsupported;
  }

  static MediaExtractor? extractorForUrl(String cleanedUrl) {
    final platform = detect(cleanedUrl);
    switch (platform) {
      case SupportedSharePlatform.youtube:
        return _youTubeExtractor;
      case SupportedSharePlatform.facebook:
      case SupportedSharePlatform.instagram:
      case SupportedSharePlatform.tiktok:
        return _socialMediaExtractor;
      case SupportedSharePlatform.unsupported:
        return null;
    }
  }

  static String platformLabel(SupportedSharePlatform platform) {
    switch (platform) {
      case SupportedSharePlatform.youtube:
        return 'youtube';
      case SupportedSharePlatform.facebook:
        return 'facebook';
      case SupportedSharePlatform.instagram:
        return 'instagram';
      case SupportedSharePlatform.tiktok:
        return 'tiktok';
      case SupportedSharePlatform.unsupported:
        return 'unsupported';
    }
  }

  static bool _hostMatches(String host, Set<String> knownHosts) {
    for (final knownHost in knownHosts) {
      if (host == knownHost || host.endsWith('.$knownHost')) {
        return true;
      }
    }

    return false;
  }
}
