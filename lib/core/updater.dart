import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// `major.minor.patch` with an optional `-dev.N` CI build suffix. A release
/// sorts above every dev build of the same version.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.dev]);

  final int major, minor, patch;
  final int? dev;

  bool get isDev => dev != null;

  static final _re = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-dev\.(\d+))?');

  static AppVersion? tryParse(String s) {
    final m = _re.firstMatch(s.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4] == null ? null : int.parse(m[4]!));
  }

  @override
  int compareTo(AppVersion o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch)]) {
      if (a != b) return a - b;
    }
    if (dev == o.dev) return 0;
    if (dev == null) return 1;
    if (o.dev == null) return -1;
    return dev! - o.dev!;
  }

  bool operator >(AppVersion o) => compareTo(o) > 0;

  @override
  String toString() => '$major.$minor.$patch${dev == null ? '' : '-dev.$dev'}';
}

class UpdateInfo {
  const UpdateInfo(this.version, this.pageUrl, this.downloadUrl, this.downloadName);
  final AppVersion version;
  final String pageUrl;

  /// Installer / package for this platform (null if the release lacks one).
  final String? downloadUrl;
  final String? downloadName;
}

/// File-name suffix of this platform's download in a release.
String get platformAssetSuffix => Platform.isWindows
    ? '-windows-x64-setup.exe'
    : Platform.isLinux
        ? '-linux-amd64.deb'
        : '-android-arm64-v8a.apk';

/// Newest release in [releases] (GitHub API JSON) above [current], or null.
/// Stable builds are only offered stable releases; dev builds also see the
/// rolling `latest` pre-release, whose version is read from its file names.
UpdateInfo? pickUpdate(List<dynamic> releases, AppVersion current, String assetSuffix) {
  UpdateInfo? best;
  final fromAsset = RegExp(r'^OpenSpeak-(\d+\.\d+\.\d+(?:-dev\.\d+)?)-');
  for (final r in releases.cast<Map<String, dynamic>>()) {
    if (r['draft'] == true) continue;
    final assets = (r['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
    var v = AppVersion.tryParse(r['tag_name'] as String? ?? '');
    if (v == null) {
      for (final a in assets) {
        final m = fromAsset.firstMatch(a['name'] as String? ?? '');
        if (m != null) {
          v = AppVersion.tryParse(m[1]!);
          break;
        }
      }
    }
    if (v == null || (v.isDev && !current.isDev) || !(v > current)) continue;
    if (best != null && !(v > best.version)) continue;
    final asset = assets.where((a) => (a['name'] as String? ?? '').endsWith(assetSuffix)).firstOrNull;
    best = UpdateInfo(v, r['html_url'] as String? ?? '', asset?['browser_download_url'] as String?, asset?['name'] as String?);
  }
  return best;
}

/// Checks GitHub Releases for a newer OpenSpeak.
class Updater extends ChangeNotifier {
  Updater(this.repo, String currentVersion) : current = AppVersion.tryParse(currentVersion) ?? const AppVersion(0, 0, 0);

  /// `owner/name`.
  final String repo;
  final AppVersion current;

  bool checking = false;
  String? error;
  UpdateInfo? available;
  DateTime? checkedAt;

  Future<void> check() async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/$repo/releases?per_page=20'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'OpenSpeak'},
      ).timeout(const Duration(seconds: 15));
      final List<dynamic> releases;
      if (res.statusCode == 200) {
        releases = jsonDecode(res.body) as List<dynamic>;
      } else if (res.statusCode == 403 || res.statusCode == 429) {
        // Anonymous API quota (60/h per IP) used up: read the web pages.
        releases = await _releasesFromWeb();
      } else {
        throw HttpException('HTTP ${res.statusCode}');
      }
      available = pickUpdate(releases, current, platformAssetSuffix);
      checkedAt = DateTime.now();
    } on TimeoutException {
      error = '连接 GitHub 超时 / GitHub timed out';
    } catch (e) {
      error = '$e';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// Same shape as the API answer, built from the releases Atom feed and
  /// each release's asset list page (not rate limited).
  Future<List<Map<String, dynamic>>> _releasesFromWeb() async {
    Future<String> get(String url) async {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'OpenSpeak'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
      return r.body;
    }

    final feed = await get('https://github.com/$repo/releases.atom');
    final tags = RegExp('/$repo/releases/tag/([^"<]+)"').allMatches(feed).map((m) => m[1]!).toSet().take(6);
    final out = <Map<String, dynamic>>[];
    for (final tag in tags) {
      final page = await get('https://github.com/$repo/releases/expanded_assets/$tag');
      final hrefs = RegExp('href="(/$repo/releases/download/[^"]+)"').allMatches(page).map((m) => m[1]!).toSet();
      out.add({
        'tag_name': tag,
        'draft': false,
        'html_url': 'https://github.com/$repo/releases/tag/$tag',
        'assets': [
          for (final h in hrefs) {'name': h.split('/').last, 'browser_download_url': 'https://github.com$h'},
        ],
      });
    }
    return out;
  }
}
