import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

class DownloadProgress {
  const DownloadProgress(this.received, this.total, this.stage, {this.source});
  final int received;
  final int total;

  /// 'download', 'extract'
  final String stage;
  final String? source;

  double? get fraction => total > 0 ? received / total : null;
}

class DownloadCancelled implements Exception {}

/// Downloads, verifies and locates models under the app support directory.
///
/// Sources are tried in order: HuggingFace loose files, hf-mirror.com, then
/// the official GitHub release archive. Partial files are resumed.
class ModelManager extends ChangeNotifier {
  late Directory root;
  late String vadPath;
  final Map<String, DownloadProgress> progress = {};
  final Map<String, String> errors = {};
  final Set<String> _cancelled = {};

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    root = Directory(p.join(support.path, 'models'));
    await root.create(recursive: true);
    vadPath = p.join(root.path, 'silero_vad.onnx');
    final vad = File(vadPath);
    if (!await vad.exists()) {
      final data = await rootBundle.load('assets/silero_vad.onnx');
      await vad.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
  }

  Directory dirOf(ModelSpec m) => Directory(p.join(root.path, m.dir));

  Map<String, String> filesOf(ModelSpec m) =>
      m.files.map((k, v) => MapEntry(k, p.join(dirOf(m).path, v)));

  bool isInstalled(ModelSpec m) =>
      File(p.join(dirOf(m).path, '.complete')).existsSync() &&
      filesOf(m).values.every(
          (f) => FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound);

  bool isBusy(ModelSpec m) => progress.containsKey(m.id);

  void cancel(ModelSpec m) => _cancelled.add(m.id);

  Future<void> delete(ModelSpec m) async {
    final d = dirOf(m);
    if (await d.exists()) await d.delete(recursive: true);
    final arc = File(p.join(root.path, m.archive));
    if (await arc.exists()) await arc.delete();
    notifyListeners();
  }

  Future<void> download(ModelSpec m) async {
    if (isBusy(m)) return;
    _cancelled.remove(m.id);
    errors.remove(m.id);
    _report(m, DownloadProgress(0, m.sizeMB * 1024 * 1024, 'download'));
    final failures = <String>[];
    try {
      if (m.onHuggingFace) {
        for (final host in ['huggingface.co', 'hf-mirror.com']) {
          try {
            await _downloadLoose(m, host);
            return;
          } on DownloadCancelled {
            rethrow;
          } catch (e) {
            failures.add('$host: $e');
          }
        }
      }
      try {
        await _downloadArchive(m);
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        failures.add('github: $e');
        throw Exception(failures.join('\n'));
      }
    } on DownloadCancelled {
      // Leave .part files so the next attempt resumes.
    } catch (e) {
      errors[m.id] = e.toString();
    } finally {
      progress.remove(m.id);
      notifyListeners();
    }
  }

  Future<void> _downloadLoose(ModelSpec m, String host) async {
    final dir = dirOf(m);
    await dir.create(recursive: true);
    final rels = m.files.values.toList();
    // Sizes first so the progress bar is accurate across files.
    final sizes = <String, int>{};
    for (final rel in rels) {
      sizes[rel] = await _contentLength(_hfUrl(host, m.dir, rel));
    }
    final total = sizes.values.fold<int>(0, (a, b) => a + b);
    var done = 0;
    for (final rel in rels) {
      final dest = File(p.join(dir.path, rel));
      if (await dest.exists() && await dest.length() == sizes[rel]) {
        done += sizes[rel]!;
        continue;
      }
      await _fetch(_hfUrl(host, m.dir, rel), dest, (got) {
        _report(m, DownloadProgress(done + got, total, 'download', source: host));
      }, m.id);
      done += sizes[rel]!;
    }
    await File(p.join(dir.path, '.complete')).writeAsString('$host\n');
  }

  Future<void> _downloadArchive(ModelSpec m) async {
    const base = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';
    final arc = File(p.join(root.path, m.archive));
    await _fetch(Uri.parse('$base/${m.archive}'), arc, (got) {
      _report(m, DownloadProgress(got, m.sizeMB * 1024 * 1024, 'download',
          source: 'github.com'));
    }, m.id);
    _report(m, const DownloadProgress(0, 0, 'extract'));
    await _extract(arc.path, root.path);
    await arc.delete();
    final dir = dirOf(m);
    await File(p.join(dir.path, '.complete')).writeAsString('github\n');
    // Test clips are not needed at runtime.
    final wavs = Directory(p.join(dir.path, 'test_wavs'));
    if (await wavs.exists()) await wavs.delete(recursive: true);
  }

  static Future<void> _extract(String archive, String dest) async {
    if (!Platform.isAndroid) {
      // System tar (also shipped with Windows 10+) is much faster than Dart.
      final r = await Process.run('tar', ['-xjf', archive, '-C', dest]);
      if (r.exitCode == 0) return;
    }
    await Isolate.run(() => extractFileToDisk(archive, dest));
  }

  Uri _hfUrl(String host, String repo, String file) =>
      Uri.parse('https://$host/csukuangfj/$repo/resolve/main/$file');

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'OpenSpeak';

  Future<int> _contentLength(Uri url) async {
    final c = _client();
    try {
      final res = await _open(c, url, 'HEAD', null);
      await res.drain<void>();
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}', uri: url);
      return res.contentLength;
    } finally {
      c.close(force: true);
    }
  }

  /// Follows redirects manually so the Range header survives CDN hops.
  Future<HttpClientResponse> _open(
      HttpClient c, Uri url, String method, int? from) async {
    var u = url;
    for (var i = 0; i < 8; i++) {
      final req = await c.openUrl(method, u);
      req.followRedirects = false;
      if (from != null && from > 0) req.headers.set('Range', 'bytes=$from-');
      final res = await req.close();
      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (loc == null) break;
        u = u.resolve(loc);
        continue;
      }
      return res;
    }
    throw HttpException('too many redirects', uri: url);
  }

  Future<void> _fetch(
      Uri url, File dest, void Function(int got) onBytes, String id) async {
    final part = File('${dest.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    final c = _client();
    try {
      final res = await _open(c, url, 'GET', have);
      if (res.statusCode == 416) {
        // Already complete.
        await res.drain<void>();
      } else {
        if (res.statusCode >= 400) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode}', uri: url);
        }
        if (res.statusCode != 206) have = 0; // server ignored Range
        final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        var got = have;
        var last = DateTime.now();
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 30))) {
            if (_cancelled.contains(id)) throw DownloadCancelled();
            sink.add(chunk);
            got += chunk.length;
            final now = DateTime.now();
            if (now.difference(last).inMilliseconds > 200) {
              last = now;
              onBytes(got);
            }
          }
        } finally {
          await sink.close();
        }
        onBytes(got);
      }
      await part.rename(dest.path);
    } finally {
      c.close(force: true);
    }
  }

  void _report(ModelSpec m, DownloadProgress pr) {
    progress[m.id] = pr;
    notifyListeners();
  }
}
