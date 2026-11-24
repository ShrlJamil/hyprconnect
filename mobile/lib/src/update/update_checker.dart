//! Over-the-air self-update from GitHub Releases. The app is
//! distributed outside any store, so it checks the project's
//! latest release itself: when the release tag is newer than the
//! installed "1.0.0+4", the APK asset is offered, downloaded with
//! its SHA-256 verified against the release's SHA256SUMS, and
//! handed to the system package installer. While the repository
//! is private the release API answers 404 to anonymous callers
//! and every check quietly finds nothing.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/native_bridge.dart';

const updateRepo = 'ShrlJamil/hyprconnect';
const _apkAssetName = 'app-release.apk';
const _sumsAssetName = 'SHA256SUMS';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

class ReleaseInfo {
  /// The release tag, e.g. "v1.0.0+4".
  final String tag;
  final String notes;
  final String apkUrl;
  final int apkSize;
  final String sumsUrl;

  const ReleaseInfo({
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    required this.sumsUrl,
  });

  /// The tag without its leading "v": "1.0.0+4".
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

/// Compare two "1.0.0+4" versions (a leading "v" is allowed):
/// negative when [a] is older, positive when newer, 0 when equal
/// or unparsable.
int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  if (pa == null || pb == null) return 0;
  for (var i = 0; i < 3; i++) {
    final x = i < pa.$1.length ? pa.$1[i] : 0;
    final y = i < pb.$1.length ? pb.$1[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return pa.$2.compareTo(pb.$2);
}

(List<int>, int)? _parseVersion(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  var build = 0;
  final plus = s.indexOf('+');
  if (plus >= 0) {
    build = int.tryParse(s.substring(plus + 1)) ?? 0;
    s = s.substring(0, plus);
  }
  final parts = <int>[];
  for (final piece in s.split('.')) {
    final n = int.tryParse(piece);
    if (n == null) return null;
    parts.add(n);
  }
  return (parts, build);
}

class UpdateChecker {
  /// The latest published release, or null when the check fails
  /// (offline, or the release is not publicly visible).
  static Future<ReleaseInfo?> fetchLatest() async {
    final client = HttpClient()..userAgent = 'HyprConnect-Android';
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://api.github.com/repos/$updateRepo/releases/latest',
        ),
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String? ?? '';
      var apkUrl = '';
      var apkSize = 0;
      var sumsUrl = '';
      final assets = json['assets'];
      if (assets is List) {
        for (final raw in assets) {
          final asset = raw as Map<String, dynamic>;
          final url = asset['browser_download_url'] as String? ?? '';
          if (asset['name'] == _apkAssetName) {
            apkUrl = url;
            apkSize = (asset['size'] as num?)?.toInt() ?? 0;
          } else if (asset['name'] == _sumsAssetName) {
            sumsUrl = url;
          }
        }
      }
      if (tag.isEmpty || apkUrl.isEmpty) return null;
      return ReleaseInfo(
        tag: tag,
        notes: json['body'] as String? ?? '',
        apkUrl: apkUrl,
        apkSize: apkSize,
        sumsUrl: sumsUrl,
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// The latest release when it is newer than this install,
  /// otherwise null (up to date, or the check failed).
  static Future<ReleaseInfo?> checkForUpdate() async {
    final current = await NativeBridge.appVersion();
    if (current == null) return null;
    final latest = await fetchLatest();
    if (latest == null) return null;
    return compareVersions(latest.version, current) > 0 ? latest : null;
  }

  /// Download the release APK into the cache directory, verifying
  /// its SHA-256 against SHA256SUMS when the release carries one.
  /// Throws [UpdateException] on any failure.
  static Future<File> downloadApk(
    ReleaseInfo info, {
    required void Function(int received, int total) onProgress,
  }) async {
    final expected = await _expectedSha(info);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/hyprconnect-update.apk');
    final client = HttpClient()..userAgent = 'HyprConnect-Android';
    try {
      final request = await client.getUrl(Uri.parse(info.apkUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw const UpdateException('download failed');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : info.apkSize;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      if (expected != null) {
        final digest = await sha256.bind(file.openRead()).single;
        if (digest.toString() != expected) {
          await file.delete();
          throw const UpdateException('checksum mismatch');
        }
      }
      return file;
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException('download failed');
    } finally {
      client.close();
    }
  }

  static Future<String?> _expectedSha(ReleaseInfo info) async {
    if (info.sumsUrl.isEmpty) return null;
    final client = HttpClient()..userAgent = 'HyprConnect-Android';
    try {
      final request = await client.getUrl(Uri.parse(info.sumsUrl));
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final text = await response.transform(utf8.decoder).join();
      for (final line in text.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts.last.endsWith(_apkAssetName)) {
          return parts.first.toLowerCase();
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
